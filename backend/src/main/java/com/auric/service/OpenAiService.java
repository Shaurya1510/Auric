package com.auric.service;

import com.auric.dto.Dtos;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.core.io.buffer.DataBufferUtils;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import reactor.core.publisher.Flux;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.*;

/**
 * Core AI orchestration service.
 *
 * Responsibilities:
 * - build system prompt + conversation payload
 * - call OpenAI text/vision models
 * - stream token chunks to controller
 * - generate async chat titles
 */
@Service
@Slf4j
public class OpenAiService {

    private static final int MAX_HISTORY_MESSAGES = 120;
    private static final int FAST_HISTORY_CHARS = 7000;
    private static final int DETAILED_HISTORY_CHARS = 18000;
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String OPENAI_FALLBACK_MODEL = "gpt-5.4-mini";
    // Lightweight HTTP client used for optional web-research enrichment.
    private static final HttpClient WEB_HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .followRedirects(HttpClient.Redirect.NORMAL)
            .build();

    private final WebClient openAiClient;
    private final String openAiApiKey;
    private final boolean webResearchEnabled;

    // OpenAI models
    private final String openAiTextModel;
    private final String openAiVisionModel;

    private final int openAiMaxTokens;

    public OpenAiService(
            @Qualifier("openAiWebClient")  WebClient openAiClient,
            @Value("${openai.api.key:}")              String openAiApiKey,
            @Value("${ai.web.research.enabled:true}") boolean webResearchEnabled,
            @Value("${openai.model:gpt-4o}")           String openAiTextModel,
            @Value("${openai.vision.model:gpt-4o}")    String openAiVisionModel,
            @Value("${openai.max.tokens:4096}")        int openAiMaxTokens) {

        this.openAiClient     = openAiClient;
        this.openAiApiKey     = openAiApiKey != null ? openAiApiKey.trim() : "";
        this.webResearchEnabled = webResearchEnabled;
        this.openAiTextModel  = openAiTextModel;
        this.openAiVisionModel= openAiVisionModel;
        this.openAiMaxTokens  = openAiMaxTokens;

        log.info("AI mode: openai | openai=({}/{})", openAiTextModel, openAiVisionModel);
    }

    // ─── Feature: streaming chat completion pipeline ─────────

    /**
     * Returns a Flux of raw text token strings.
     * Also emits one special "§PROVIDER:openai" token at the
     * very start so the controller can include it in the SSE meta event.
     */
    public Flux<String> streamChat(String userMessage,
                                   List<Dtos.HistoryMessage> history,
                                   String imageData,
                                   String imageMimeType,
                                   List<String> imageDataList,
                                   List<String> imageMimeTypeList,
                                   String responseMode) {

        List<String> normalizedImages = normalizeImageInputs(imageData, imageMimeType, imageDataList, imageMimeTypeList);
        boolean hasImage = !normalizedImages.isEmpty();
        boolean fastMode = responseMode == null || !"detailed".equalsIgnoreCase(responseMode.trim());
        boolean forceDetailed = shouldForceDetailedMode(userMessage, hasImage);
        boolean effectiveFastMode = fastMode && !forceDetailed;
        boolean isComplex = detectComplexQuestion(userMessage);

        final WebClient client = openAiClient;
        final String model = hasImage ? openAiVisionModel : openAiTextModel;
        final int maxTok = openAiMaxTokens;
        final String provName = "openai";
        final int modeMaxTok = estimateOutputTokenCap(userMessage, hasImage, effectiveFastMode, isComplex);
        final double modeTemp = effectiveFastMode ? 0.08 : 0.16;

        log.info("streamChat provider={} model={} hasImage={} mode={} msgLen={}",
                provName, model, hasImage, effectiveFastMode ? "fast" : "detailed", userMessage == null ? 0 : userMessage.length());

        // Build the model message list (system prompt + history + current turn).
        List<Map<String, Object>> messages = buildMessages(
                userMessage, history, normalizedImages, hasImage, effectiveFastMode);

        Map<String, Object> requestBody = new LinkedHashMap<>();
        requestBody.put("model", model);
        requestBody.put("messages", messages);
        requestBody.put("max_completion_tokens", modeMaxTok);
        requestBody.put("temperature", modeTemp);
        // Slightly tighter sampling for more deterministic, reliable answers.
        requestBody.put("top_p", 0.85);
        // Keep repetition control mild so responses stay natural.
        requestBody.put("frequency_penalty", 0.05);
        requestBody.put("stream", true);

        // First emit a synthetic token the controller uses to build the meta event
        Flux<String> providerSignal = Flux.just("§PROVIDER:" + provName);

        if (!hasOpenAiKey()) {
            return Flux.concat(
                providerSignal,
                Flux.just("\n\n⚠️ OpenAI API key is missing. Add OPENAI_API_KEY in backend/.env or system environment and restart backend.")
            );
        }

        // Stream token chunks; convert backend/provider issues into user-readable warnings.
        Flux<String> tokenStream = streamOpenAiWithFallback(client, requestBody, model)
                .onErrorResume(WebClientResponseException.class, ex -> {
                    log.error("{} API error {}: {}", provName, ex.getStatusCode(), ex.getResponseBodyAsString());
                    return Flux.just(formatOpenAiError(ex));
                })
                .onErrorResume(Exception.class, ex -> {
                    log.error("{} stream error: {}", provName, ex.getMessage());
                    return Flux.just("\n\n⚠️ Could not reach OpenAI. Check your internet connection.");
                });

        return Flux.concat(providerSignal, tokenStream);
    }

    // ─── Feature: async chat-title generation ────────────────

    public String generateTitle(String firstMessage) {
        if (!hasOpenAiKey()) return "New Chat";

        // Smart prompt: produce a short but descriptive, human-worthy title
        List<Map<String, Object>> messages = List.of(
            Map.of("role", "system", "content",
                "Generate a concise, descriptive chat title (3-6 words) based on the user's opening message.\n" +
                "Rules:\n" +
                "- Capture the specific topic, not a generic category.\n" +
                "- Use title case (capitalise main words).\n" +
                "- No quotes, no punctuation at the end, no filler like 'Chat about' or 'Discussion of'.\n" +
                "- If the message is a math/physics/engineering problem, start with the concept name.\n" +
                "- If it is a code question, include the language or framework.\n" +
                "- Examples: 'Fourier Transform Intuition', 'Python Binary Search Tree', 'Quantum Tunneling Explained'."),
            Map.of("role", "user", "content",
                firstMessage.length() > 300 ? firstMessage.substring(0, 300) : firstMessage)
        );

        try {
            JsonNode response = requestTitle(messages, openAiTextModel);
            if (response == null) {
                response = requestTitle(messages, OPENAI_FALLBACK_MODEL);
            }

            if (response != null && response.has("choices") && response.get("choices").size() > 0) {
                String title = response.get("choices").get(0).get("message").get("content").asText().trim();
                // Strip surrounding quotes the model sometimes adds
                title = title.replaceAll("^[\"']+|[\"']+$", "").trim();
                return title.isEmpty() ? "New Chat" : title;
            }
        } catch (Exception e) {
            log.warn("Title generation failed (OpenAI): {} - using default", e.getMessage());
        }
        return "New Chat";
    }

    // ─── Internal helpers ────────────────────────────────────

    private boolean hasOpenAiKey() {
        return !openAiApiKey.isBlank();
    }

    private String formatOpenAiError(WebClientResponseException ex) {
        int code = ex.getStatusCode().value();
        String body = ex.getResponseBodyAsString();
        if (code == 401) {
            return "\n\n⚠️ OpenAI rejected the key (401). Set a valid OPENAI_API_KEY and restart backend.";
        }
        if (code == 429) {
            return "\n\n⚠️ OpenAI rate limit reached. Wait a bit or check quota/billing on your OpenAI account.";
        }
        if (code >= 500) {
            return "\n\n⚠️ OpenAI server error. Please retry in a moment.";
        }
        if (body != null && body.toLowerCase(Locale.ROOT).contains("model")) {
            return "\n\n⚠️ Selected model is unavailable for your API key. Set OPENAI_MODEL to an available one (for example gpt-4o).";
        }
        return "\n\n⚠️ OpenAI request failed (" + code + "). Please retry.";
    }

    // Builds the final OpenAI payload messages list.
    private List<Map<String, Object>> buildMessages(String userMessage,
                                                      List<Dtos.HistoryMessage> history,
                                                      List<String> imageUrls,
                                                      boolean hasImage,
                                                      boolean fastMode) {
        List<Map<String, Object>> messages = new ArrayList<>();
        boolean isComplex = detectComplexQuestion(userMessage);
        SubjectDomain subject = detectSubjectDomain(userMessage);
        ResponseIntent intent = detectResponseIntent(userMessage);
        String expertBlock  = buildSubjectExpertBlock(subject);
        String intentBlock  = buildResponseIntentBlock(intent);
        String levelBlock   = detectUserLevel(userMessage, history);
        String teachingBlock = buildTeachingStyleBlock(userMessage, hasImage, isComplex);
        String qualityBlock = buildQualityGuardrailsBlock(userMessage, hasImage, isComplex);

        String systemPrompt;
        if (fastMode) {
            systemPrompt =
                "You are Auric. Give accurate, concise answers. " +
                "Lead with the direct answer, then only essential detail.\n\n" +
                "Rules:\n" +
                "- No hallucinations. If uncertain, say so briefly.\n" +
                "- If key inputs are missing, ask one concise clarification question before giving the final answer.\n" +
                "- Keep responses compact unless user explicitly asks for depth.\n" +
                "- Never end mid-solution. If solving, always include the final numeric/algebraic result.\n" +
                "- For math: use display equations with $$...$$ for main formulas, then show steps and final unit-checked answer.\n" +
                "- For code: root cause in one sentence + corrected runnable snippet.\n" +
                (hasImage
                    ? "- For images: inspect ALL provided images, cross-check them before finalizing, and cite which image observation supports each conclusion. " +
                      "Identify chart axes/labels/units first, then compute requested values from visible evidence. " +
                      "If details are unreadable, state what is missing and ask for a clearer crop.\n"
                    : "") +
                (isComplex ? "- Problem is complex: still show clear step-by-step reasoning.\n" : "") +
                qualityBlock + expertBlock + intentBlock + levelBlock + teachingBlock;
        } else {
            systemPrompt =
                "You are Auric, a precise tutor-level assistant.\n\n" +
                "Core rules:\n" +
                "- Be correct, explicit, and structured.\n" +
                "- Do not invent facts or calculations.\n" +
                "- If critical context is missing, ask one short clarifying question before finalizing.\n" +
                "- Define symbols and include units for numeric results.\n" +
                "- For multi-step tasks, show steps clearly and finish with a final answer section.\n" +
                "- Keep explanations useful, not verbose filler.\n\n" +
                "For formulas, use display math with $$...$$ for key equations and define variables after equations. " +
                "Prefer $...$ for inline symbols; avoid raw escaped delimiters like \\(...\\) and \\[...\\].\n" +
                "For code, provide complete runnable examples when requested.\n" +
                (hasImage
                    ? "For images: inspect ALL provided images, cross-check consistency, then answer. " +
                      "Describe and extract relevant text/equations, and for graphs/circuits explicitly read axes/scale/units before solving. " +
                      "If image quality is insufficient, state uncertainty and request a clearer image or zoomed crop.\n"
                    : "") +
                (isComplex ? "Complex task detected: reason methodically and verify the result.\n" : "") +
                qualityBlock + expertBlock + intentBlock + levelBlock + teachingBlock;
        }

        messages.add(Map.of(
            "role", "system",
            "content", systemPrompt
        ));

        // Keep research opt-in by complexity to avoid unnecessary token spend.
        boolean shouldResearch = webResearchEnabled && !hasImage
                && !fastMode
                && isFactualQuestion(userMessage);
        if (shouldResearch) {
            String query = extractWebSearchQuery(userMessage);
            String webContext = buildWebResearchContext(query);
            if (!webContext.isBlank()) {
                messages.add(Map.of(
                    "role", "system",
                    "content", "Web research snippets (public sources — use as supporting context, not as sole authority):\n" + webContext
                ));
            }
        }

        // Conversation memory with tighter token budget controls.
        if (history != null && !history.isEmpty()) {
            int historyLimit = fastMode ? Math.min(40, MAX_HISTORY_MESSAGES) : Math.min(90, MAX_HISTORY_MESSAGES);
            int start = Math.max(0, history.size() - historyLimit);
            int charBudget = fastMode ? FAST_HISTORY_CHARS : DETAILED_HISTORY_CHARS;
            int usedChars = 0;
            List<Dtos.HistoryMessage> selected = new ArrayList<>();
            List<Dtos.HistoryMessage> window = history.subList(start, history.size());
            int guaranteedRecent = Math.min(window.size(), fastMode ? 8 : 12);

            for (int i = window.size() - 1; i >= 0; i--) {
                Dtos.HistoryMessage h = window.get(i);
                if (h == null || h.getContent() == null || h.getContent().isBlank()) continue;
                String compactContent = trimTo(h.getContent().trim(), fastMode ? 700 : 1200);
                int contentLen = compactContent.length();
                int distanceFromEnd = window.size() - 1 - i;
                boolean isRecentProtected = distanceFromEnd < guaranteedRecent;
                if (!isRecentProtected && !selected.isEmpty() && usedChars + contentLen > charBudget) {
                    break;
                }
                selected.add(new Dtos.HistoryMessage(h.getRole(), compactContent));
                usedChars += contentLen;
            }

            Collections.reverse(selected);
            for (Dtos.HistoryMessage h : selected) {
                messages.add(Map.of(
                    "role", normalizeRole(h.getRole()),
                    "content", h.getContent()
                ));
            }
        }

        // Current user turn (text-only or multimodal with images).
        if (hasImage) {
            List<Map<String, Object>> multiContent = new ArrayList<>();
            String imageInstruction = imageUrls.size() > 1
                    ? "You received multiple images. Review every image, cross-check details between them, then answer."
                    : "You received one image. Extract details carefully before answering.";
            String userText = userMessage == null || userMessage.isBlank()
                    ? "Describe and analyze these image(s) in detail."
                    : userMessage;
            multiContent.add(Map.of("type", "text", "text", imageInstruction + "\n" + userText));
            for (String url : imageUrls) {
                multiContent.add(Map.of("type", "image_url", "image_url", Map.of("url", url, "detail", selectImageDetailLevel(fastMode, isComplex, userMessage))));
            }
            messages.add(Map.of("role", "user", "content", multiContent));
        } else {
            messages.add(Map.of("role", "user", "content",
                userMessage == null || userMessage.isBlank() ? "(empty message)" : userMessage));
        }

        return messages;
    }

    /**
     * Detects whether a question likely requires multi-step reasoning,
     * math derivations, or complex problem-solving — so the system prompt
     * can instruct the model to work more methodically.
     */
    private boolean detectComplexQuestion(String message) {
        if (message == null || message.isBlank()) return false;
        String lower = message.toLowerCase(Locale.ROOT);

        // Keywords that signal multi-step or conceptual depth
        String[] indicators = {
            "prove", "derive", "derivation", "proof", "calculate", "compute", "solve",
            "integrate", "differentiate", "laplace", "fourier", "eigenvalue", "eigenvector",
            "matrix", "determinant", "inverse", "algorithm", "complexity", "big o",
            "debug", "why does", "how does", "explain how", "explain why",
            "step by step", "step-by-step", "walk me through", "show me how",
            "what is the difference between", "compare and contrast",
            "theorem", "lemma", "corollary", "hypothesis",
            "design pattern", "architecture", "optimize", "optimisation", "optimization",
            "implement", "refactor", "circuit", "frequency response", "transfer function",
            "differential equation", "probability", "statistics", "regression",
            "gradient", "neural", "transformer", "convolution", "recursion", "dynamic programming"
        };
        for (String indicator : indicators) {
            if (lower.contains(indicator)) return true;
        }

        // Math / science symbols strongly suggest a technical question
        String[] mathSymbols = { "∫", "∑", "∂", "∇", "√", "∞", "≤", "≥", "∈", "∀", "∃", "⊕", "⊗", "→", "⇒" };
        for (String sym : mathSymbols) {
            if (message.contains(sym)) return true;
        }

        // Inline LaTeX patterns suggest a math question
        if (message.contains("\\(") || message.contains("$$") || message.contains("\\frac")
                || message.contains("\\int") || message.contains("\\sum")) return true;

        // Equation-like patterns (has = and at least one math operator) on a non-trivial string
        boolean hasEquals  = message.contains("=");
        boolean hasMathOp  = message.contains("+") || message.contains("*")
                          || message.contains("^") || message.contains("/");
        if (hasEquals && hasMathOp && message.length() > 20) return true;

        // Long questions are generally more complex
        return message.length() > 300;
    }

    // ─── Feature: subject-domain detection ───────────────────

    private enum SubjectDomain {
        PHYSICS, CHEMISTRY, MATHEMATICS, PROGRAMMING, BIOLOGY, ENGINEERING, GENERAL
    }

    private SubjectDomain detectSubjectDomain(String message) {
        if (message == null || message.isBlank()) return SubjectDomain.GENERAL;
        String lower = message.toLowerCase(Locale.ROOT);

        if (matchesAny(lower, "newton", "force", "momentum", "velocity", "acceleration",
                "electric field", "magnetic", "circuit", "resistance", "voltage", "current",
                "power", "thermodynamics", "entropy", "quantum", "photon", "electron",
                "nuclear", "relativity", "gravity", "torque", "angular momentum", "capacitor",
                "inductor", "semiconductor", "optics", "refraction", "diffraction",
                "doppler", "kirchhoff", "ohm", "faraday", "maxwell", "biot", "coulomb"))
            return SubjectDomain.PHYSICS;

        if (matchesAny(lower, "molecule", "compound", "chemical reaction", "acid", "base",
                "oxidation", "reduction", "covalent", "ionic bond", "organic", "polymer",
                "catalyst", "equilibrium constant", "molar", "stoichiometry", "titration",
                "enthalpy", "gibbs", "electronegativity", "isomer", "periodic table",
                "valence electron", "lewis structure"))
            return SubjectDomain.CHEMISTRY;

        if (matchesAny(lower, "integral", "derivative", "limit", "matrix", "vector space",
                "eigenvalue", "differential equation", "fourier", "laplace transform",
                "probability", "statistics", "combinatorics", "number theory", "prime",
                "modular arithmetic", "calculus", "series convergence", "gradient", "hessian",
                "linear programming", "set theory", "topology", "complex analysis"))
            return SubjectDomain.MATHEMATICS;

        if (matchesAny(lower, "code", "function", "class", "method", "variable", "array",
                "loop", "recursion", "algorithm", "data structure", "api", "database", "sql",
                "javascript", "python", "java", "kotlin", "typescript", "react", "angular",
                "node.js", "backend", "frontend", "debug", "exception", "runtime error",
                "compile", "framework", "machine learning", "neural network", "tensorflow",
                "pytorch", "git", "docker", "kubernetes", "rest api", "graphql"))
            return SubjectDomain.PROGRAMMING;

        if (matchesAny(lower, "cell", "dna", "rna", "protein", "enzyme", "gene", "chromosome",
                "evolution", "natural selection", "photosynthesis", "mitosis", "meiosis",
                "neuron", "synapse", "hormone", "bacteria", "virus", "immune system",
                "ecosystem", "metabolism", "atp", "krebs cycle", "glycolysis"))
            return SubjectDomain.BIOLOGY;

        if (matchesAny(lower, "mechanical", "civil engineering", "structural", "beam",
                "stress", "strain", "material science", "fluid dynamics", "control system",
                "pid controller", "transfer function", "bode plot", "nyquist", "fpga",
                "microcontroller", "signal processing", "filter design", "amplifier",
                "embedded system", "pcb", "schematic"))
            return SubjectDomain.ENGINEERING;

        return SubjectDomain.GENERAL;
    }

    private String buildSubjectExpertBlock(SubjectDomain domain) {
        return switch (domain) {
            case PHYSICS ->
                "## Subject Expertise: Physics\n" +
                "- Apply and name the governing law/principle before using it (Newton's 2nd law, Kirchhoff's KVL, Faraday's induction law, etc.).\n" +
                "- Use strict SI units throughout; include unit analysis in every step.\n" +
                "- For circuit problems: use KVL / KCL systematically; redraw sub-circuits if helpful.\n" +
                "- For mechanics: identify the system, describe forces, then apply F = ma or energy conservation.\n" +
                "- State fundamental constants with values: \\(g = 9.81\\) m/s², \\(c = 3×10^8\\) m/s, etc.\n" +
                "- Verify: are the units right? Is the magnitude physically plausible?\n\n";
            case CHEMISTRY ->
                "## Subject Expertise: Chemistry\n" +
                "- Balance every equation and verify conservation of atoms and charge.\n" +
                "- Include state symbols: (s), (l), (g), (aq).\n" +
                "- Use IUPAC nomenclature for all compounds.\n" +
                "- For thermochemistry: sign conventions (exothermic ΔH < 0), Hess's law, standard states.\n" +
                "- For equilibrium: write K expression, apply Le Chatelier's principle explicitly.\n" +
                "- Show significant figures consistent with given data.\n\n";
            case MATHEMATICS ->
                "## Subject Expertise: Mathematics\n" +
                "- Name theorems/identities before applying: 'By the Fundamental Theorem of Calculus…'\n" +
                "- For proofs: state what you are proving, choose method (direct / induction / contradiction), label QED.\n" +
                "- State domain/range restrictions and justify where operations are valid.\n" +
                "- For series: always check convergence before summing.\n" +
                "- For linear algebra: state matrix dimensions; verify operations are well-defined.\n" +
                "- After solving, substitute back into the original equation to verify.\n\n";
            case PROGRAMMING ->
                "## Subject Expertise: Programming\n" +
                "- State the language and version when relevant (Python 3.12, Java 21, Node 20).\n" +
                "- For algorithms: state approach + time complexity O(…) + space complexity O(…).\n" +
                "- For bugs: identify root cause first, show minimal reproduction, then the corrected code.\n" +
                "- Write production-quality code: error handling, input validation, sensible variable names.\n" +
                "- Call out edge cases: empty input, null/undefined, integer overflow, off-by-one.\n" +
                "- For architecture decisions: weigh trade-offs (performance vs. readability, coupling vs. flexibility).\n\n";
            case BIOLOGY ->
                "## Subject Expertise: Biology\n" +
                "- Use correct scientific names alongside common names.\n" +
                "- Connect molecular mechanisms to their physiological outcome.\n" +
                "- Name pathways explicitly: Krebs cycle, glycolysis, Calvin cycle, etc.\n" +
                "- For genetics: use standard notation (dominant uppercase, recessive lowercase).\n" +
                "- Relate everything back to the evolutionary or adaptive significance.\n\n";
            case ENGINEERING ->
                "## Subject Expertise: Engineering\n" +
                "- Quote the relevant standard, law, or empirical rule before applying it.\n" +
                "- For control systems: write transfer function, check stability (poles, Bode, Routh).\n" +
                "- For signal processing: specify sampling rate, Nyquist criterion, filter specifications.\n" +
                "- For structural problems: identify load path, then choose analysis method.\n" +
                "- Always state safety factor and note real-world constraints (cost, material availability).\n" +
                "- End with a practical design recommendation.\n\n";
            default -> "";
        };
    }

    // ─── Feature: response-intent detection ──────────────────

    private enum ResponseIntent {
        DEFINITION, COMPARISON, HOW_IT_WORKS, CALCULATION, DEBUGGING,
        STEP_BY_STEP, OPINION, GENERAL
    }

    private ResponseIntent detectResponseIntent(String message) {
        if (message == null || message.isBlank()) return ResponseIntent.GENERAL;
        String lower = message.toLowerCase(Locale.ROOT);

        if (matchesAny(lower, "what is ", "what are ", "define ", "definition of ", "meaning of "))
            return ResponseIntent.DEFINITION;
        if (matchesAny(lower, " vs ", " versus ", "difference between", "compare", "which is better",
                "pros and cons", "advantages and disadvantages"))
            return ResponseIntent.COMPARISON;
        if (matchesAny(lower, "how does", "how do", "how is", "explain how", "why does", "mechanism",
                "how it works", "what happens when"))
            return ResponseIntent.HOW_IT_WORKS;
        if (matchesAny(lower, "calculate", "compute", "find the", "solve", "evaluate",
                "what is the value", "how much", "how many"))
            return ResponseIntent.CALCULATION;
        if (matchesAny(lower, "debug", "fix", "error", "not working", "broken", "bug", "crash",
                "exception", "fails", "issue with my", "wrong output"))
            return ResponseIntent.DEBUGGING;
        if (matchesAny(lower, "step by step", "how to", "walk me through", "guide me",
                "tutorial", "show me how", "how do i"))
            return ResponseIntent.STEP_BY_STEP;
        if (matchesAny(lower, "your opinion", "do you think", "should i", "recommend",
                "best way", "what would you"))
            return ResponseIntent.OPINION;

        return ResponseIntent.GENERAL;
    }

    private String buildResponseIntentBlock(ResponseIntent intent) {
        return switch (intent) {
            case DEFINITION ->
                "## Response Structure: Definition\n" +
                "1. One-sentence definition (precise, no fluff).\n" +
                "2. Key characteristics — 3-4 bullets.\n" +
                "3. Concrete analogy or intuitive example.\n" +
                "4. Where / when it is used (applications).\n\n";
            case COMPARISON ->
                "## Response Structure: Comparison\n" +
                "Use a Markdown table as the centrepiece: | Feature | Option A | Option B |.\n" +
                "Follow with 'When to choose A' and 'When to choose B' sections.\n" +
                "End with a clear recommendation if the context permits.\n\n";
            case HOW_IT_WORKS ->
                "## Response Structure: Mechanism\n" +
                "1. One-sentence summary of what happens.\n" +
                "2. Numbered step-by-step mechanism.\n" +
                "3. Analogy to make it intuitive.\n" +
                "4. Real-world implication or application.\n\n";
            case CALCULATION ->
                "## Response Structure: Calculation\n" +
                "Follow strictly: Formula → Where block → Substitute values → " +
                "Step-by-step arithmetic → Final answer (bold, with units) → Unit verification → Result interpretation.\n\n";
            case DEBUGGING ->
                "## Response Structure: Debugging\n" +
                "1. **Root Cause** — 1-2 sentences, be specific about what went wrong and why.\n" +
                "2. **Fixed Code** — complete and runnable.\n" +
                "3. **What Changed** — comment the key fix lines.\n" +
                "4. **Edge Cases to Watch** — 2-3 related pitfalls.\n\n";
            case STEP_BY_STEP ->
                "## Response Structure: Step-by-Step Guide\n" +
                "Number every step. Each step = action + brief 'why'. " +
                "Show expected output after key steps. " +
                "End with 'What you should see now' and 'Common issues'.\n\n";
            case OPINION ->
                "## Response Structure: Recommendation\n" +
                "Present 2-3 options with clear pros/cons each. " +
                "State your recommendation with explicit reasoning. " +
                "Use 'If X then Y' conditionals where the answer depends on context.\n\n";
            default -> "";
        };
    }

    private String buildTeachingStyleBlock(String userMessage, boolean hasImage, boolean isComplex) {
        String lower = userMessage == null ? "" : userMessage.toLowerCase(Locale.ROOT);
        boolean kidFriendly = matchesAny(lower,
                "simple", "easy", "kid", "school", "class", "beginner", "new to", "explain like");

        StringBuilder out = new StringBuilder();
        out.append("## Teaching Style\n")
           .append("- Give a direct answer in plain language first sentence, without forced section headings.\n")
           .append("- If solving is needed, continue with clear numbered steps.\n")
           .append("- Ensure the final conclusion and units (if numeric) are explicit.\n")
           .append("- Keep language friendly and easy to follow; avoid unnecessary jargon.\n");

        if (kidFriendly) {
            out.append("- Since user sounds like a learner, include one simple analogy and one quick check question.\n");
        }
        if (hasImage) {
            out.append("- For image questions, explicitly list what you read (axes, scale, labels, peaks), then compute from that.\n");
        }
        if (isComplex) {
            out.append("- For hard problems, include a compact verification step after solving.\n");
        }
        out.append("\n");
        return out.toString();
    }

    private String buildQualityGuardrailsBlock(String userMessage, boolean hasImage, boolean isComplex) {
        String lower = userMessage == null ? "" : userMessage.toLowerCase(Locale.ROOT);
        boolean asksForPrecision = matchesAny(lower,
                "exact", "accurate", "precision", "correct", "verify", "double check", "right answer");

        StringBuilder out = new StringBuilder();
        out.append("## Quality Guardrails\n")
           .append("- Before finalizing, silently verify that your answer directly addresses the user's latest request.\n")
           .append("- Do not contradict earlier established facts in this chat; if conflict appears, call it out and resolve it.\n")
           .append("- For calculations, re-check arithmetic and include the final value clearly labeled.\n")
           .append("- For code, ensure examples are runnable and consistent with the stated language/framework.\n");

        if (hasImage) {
            out.append("- Ground conclusions in visible evidence from the image(s); do not guess unreadable details.\n");
        }
        if (isComplex || asksForPrecision) {
            out.append("- Add one compact verification line at the end (sanity check, constraint check, or edge-case check).\n");
        }
        out.append("\n");
        return out.toString();
    }

    // ─── Feature: user expertise calibration ─────────────────

    /**
     * Detects whether the user appears to be a beginner or expert
     * from their message phrasing and conversation history.
     * Returns a string block to inject into the system prompt,
     * or blank if no strong signal found.
     */
    private String detectUserLevel(String userMessage, List<Dtos.HistoryMessage> history) {
        if (userMessage == null || userMessage.isBlank()) return "";
        String lower = userMessage.toLowerCase(Locale.ROOT);

        boolean looksLikeBeginner = matchesAny(lower,
                "what is", "i don't understand", "explain to me", "i'm new", "beginner",
                "confused", "simple explanation", "for dummies", "i don't know",
                "basics", "fundamentals", "where do i start", "eli5");

        boolean looksLikeExpert = userMessage.contains("O(") ||
                matchesAny(lower,
                        "asymptotically", "convergence", "eigenvector", "hamiltonian",
                        "manifold", "isomorphism", "stochastic process", "bayesian",
                        "hyperparameter", "gradient descent", "backpropagation",
                        "kolmogorov", "lebesgue", "p-value", "null hypothesis",
                        "memoization", "amortized", "tail recursion");

        // Boost expert signal from history
        if (!looksLikeExpert && history != null) {
            long expertMsgs = history.stream()
                    .filter(h -> h != null && h.getContent() != null && h.getContent().length() > 80)
                    .filter(h -> matchesAny(h.getContent().toLowerCase(Locale.ROOT),
                            "asymptot", "eigenv", "hamilton", "manifold", "stochastic",
                            "backprop", "amortized", "lebesgue"))
                    .count();
            if (expertMsgs >= 2) looksLikeExpert = true;
        }

        if (looksLikeBeginner) {
            return "## User Level: Beginner\n" +
                   "Use simple language and concrete everyday analogies. " +
                   "Define any jargon before using it. " +
                   "Build from the most basic concept upward. " +
                   "Encourage curiosity — add a brief 'want to explore further?' pointer.\n\n";
        } else if (looksLikeExpert) {
            return "## User Level: Expert\n" +
                   "Assume familiarity with standard terminology — skip elementary definitions. " +
                   "Be rigorous and precise. Include edge cases, nuanced caveats, and deeper insights. " +
                   "Treat them as a peer.\n\n";
        }
        return "";
    }

    // ─── Feature: optional web-research enrichment ───────────

    /**
     * Returns true for factual / current-events questions that benefit
     * from web search even in fast mode.
     */
    private boolean isFactualQuestion(String message) {
        if (message == null || message.isBlank()) return false;
        String lower = message.toLowerCase(Locale.ROOT);
        return matchesAny(lower,
                "what is the latest", "current", "today", "2024", "2025", "2026",
                "recently", "news", "update", "just released", "who invented",
                "when was", "who is", "where is", "how many", "what happened",
                "price of", "population of", "capital of");
    }

    /**
     * Extracts a clean, concise search query from the user's message
     * by stripping conversational filler words.
     */
    private String extractWebSearchQuery(String message) {
        if (message == null || message.isBlank()) return "";
        String query = message.trim();
        // Remove leading question phrases
        query = query.replaceFirst(
                "(?i)^(can you (explain|tell me|describe)|please (explain|describe|tell me)|" +
                "what (is|are|was|were)|who (is|was)|where (is|was)|when (is|was|did)|" +
                "how (does|do|did|is)|why (does|do|did|is|are)|explain|define|describe|" +
                "tell me about|i want to know about|show me)\\s+",
                "");
        // Strip trailing question mark and filler
        query = query.replaceAll("[?]+$", "").trim();
        // Collapse whitespace
        query = query.replaceAll("\\s+", " ").trim();
        // Cap at 180 chars for a focused query
        return query.length() > 180 ? query.substring(0, 180) : query;
    }

    /** General-purpose contains-any helper. */
    private boolean matchesAny(String text, String... patterns) {
        for (String pattern : patterns) {
            if (text.contains(pattern)) return true;
        }
        return false;
    }

    private int estimateOutputTokenCap(String userMessage,
                                       boolean hasImage,
                                       boolean fastMode,
                                       boolean isComplex) {
        int base = fastMode ? 900 : 1500;
        int len = userMessage == null ? 0 : userMessage.length();

        if (len > 120) base += 220;
        if (len > 320) base += 320;
        if (hasImage) base += fastMode ? 420 : 620;
        if (isComplex) base += fastMode ? 750 : 1100;
        if (userMessage != null) {
            String lower = userMessage.toLowerCase(Locale.ROOT);
            if (matchesAny(lower,
                    "step by step", "explain in detail", "derive", "proof", "calculate", "solve", "show full")) {
                base += fastMode ? 520 : 720;
            }
        }

        int cap = fastMode ? 3200 : 4600;
        return Math.max(700, Math.min(Math.min(openAiMaxTokens, cap), base));
    }

    private String selectImageDetailLevel(boolean fastMode, boolean isComplex, String userMessage) {
        if (!fastMode) return "high";
        String lower = userMessage == null ? "" : userMessage.toLowerCase(Locale.ROOT);
        boolean needsFineDetail = isComplex
                || matchesAny(lower,
                    "equation", "diagram", "proof", "circuit", "small text", "ocr", "read text",
                    "graph", "plot", "waveform", "vpp", "vpeak", "peak to peak", "axis", "scale", "oscilloscope");
        return needsFineDetail ? "high" : "high";
    }

    private boolean shouldForceDetailedMode(String userMessage, boolean hasImage) {
        String lower = userMessage == null ? "" : userMessage.toLowerCase(Locale.ROOT);
        if (matchesAny(lower,
                "step by step", "explain in detail", "derive", "proof", "show full", "solve", "calculate")) {
            return true;
        }
        if (hasImage && matchesAny(lower,
                "graph", "plot", "waveform", "vpp", "vpeak", "peak to peak", "circuit", "oscilloscope", "read values")) {
            return true;
        }
        return false;
    }

    private String normalizeImageUrl(String imageData, String imageMimeType) {
        if (imageData == null) return "";
        String trimmed = imageData.trim();
        if (trimmed.startsWith("data:image/")) return trimmed;
        if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) return trimmed;
        String mime = (imageMimeType != null && !imageMimeType.isBlank())
                ? imageMimeType.trim().split(";")[0].trim()
                : "image/jpeg";
        return "data:" + mime + ";base64," + trimmed;
    }

    private List<String> normalizeImageInputs(String imageData,
                                              String imageMimeType,
                                              List<String> imageDataList,
                                              List<String> imageMimeTypeList) {
        List<String> urls = new ArrayList<>();

        if (imageDataList != null && !imageDataList.isEmpty()) {
            for (int i = 0; i < imageDataList.size(); i++) {
                String raw = imageDataList.get(i);
                if (raw == null || raw.isBlank()) continue;
                String mime = (imageMimeTypeList != null && i < imageMimeTypeList.size())
                        ? imageMimeTypeList.get(i)
                        : imageMimeType;
                urls.add(normalizeImageUrl(raw, mime));
            }
            if (!urls.isEmpty()) return urls;
        }

        if (imageData != null && !imageData.isBlank()) {
            urls.add(normalizeImageUrl(imageData, imageMimeType));
        }
        return urls;
    }

    private String normalizeRole(String role) {
        if (role == null || role.isBlank()) return "user";
        return switch (role.toLowerCase(Locale.ROOT)) {
            case "assistant", "model" -> "assistant";
            case "system"             -> "system";
            default                   -> "user";
        };
    }

    private String buildWebResearchContext(String query) {
        if (query == null || query.isBlank()) return "";
        String compactQuery = query.trim();
        if (compactQuery.length() > 220) compactQuery = compactQuery.substring(0, 220);

        List<String> lines = new ArrayList<>();

        // Primary source: DuckDuckGo instant answer + related topics.
        try {
            String encoded = URLEncoder.encode(compactQuery, StandardCharsets.UTF_8);
            String ddgUrl = "https://api.duckduckgo.com/?q=" + encoded + "&format=json&no_html=1&skip_disambig=1";
            JsonNode ddg = fetchJson(ddgUrl, 7);
            if (ddg != null) {
                String abstractText = ddg.path("AbstractText").asText("").trim();
                String abstractUrl = ddg.path("AbstractURL").asText("").trim();
                if (!abstractText.isEmpty() && !abstractUrl.isEmpty()) {
                    lines.add("- " + trimTo(abstractText, 240) + " [" + abstractUrl + "]");
                }

                int addedFromRelated = 0;
                JsonNode related = ddg.path("RelatedTopics");
                if (related.isArray()) {
                    for (JsonNode item : related) {
                        if (addedFromRelated >= 2) break;
                        String text = item.path("Text").asText("").trim();
                        String url = item.path("FirstURL").asText("").trim();

                        if ((text.isEmpty() || url.isEmpty()) && item.has("Topics") && item.path("Topics").isArray()) {
                            for (JsonNode nested : item.path("Topics")) {
                                if (addedFromRelated >= 2) break;
                                String nestedText = nested.path("Text").asText("").trim();
                                String nestedUrl = nested.path("FirstURL").asText("").trim();
                                if (!nestedText.isEmpty() && !nestedUrl.isEmpty()) {
                                    lines.add("- " + trimTo(nestedText, 200) + " [" + nestedUrl + "]");
                                    addedFromRelated++;
                                }
                            }
                        } else if (!text.isEmpty() && !url.isEmpty()) {
                            lines.add("- " + trimTo(text, 200) + " [" + url + "]");
                            addedFromRelated++;
                        }
                    }
                }
            }
        } catch (Exception e) {
            log.debug("DuckDuckGo context fetch skipped: {}", e.getMessage());
        }

        // Fallback source: Wikipedia search snippets.
        if (lines.isEmpty()) {
            try {
                String encoded = URLEncoder.encode(compactQuery, StandardCharsets.UTF_8);
                String wikiUrl = "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=" +
                        encoded + "&format=json&utf8=1&srlimit=3";
                JsonNode wiki = fetchJson(wikiUrl, 7);
                if (wiki != null && wiki.path("query").path("search").isArray()) {
                    for (JsonNode item : wiki.path("query").path("search")) {
                        String title = item.path("title").asText("").trim();
                        String snippet = stripHtml(item.path("snippet").asText("")).trim();
                        String pageId = item.path("pageid").asText("").trim();
                        if (!title.isEmpty() && !snippet.isEmpty() && !pageId.isEmpty()) {
                            String source = "https://en.wikipedia.org/?curid=" + pageId;
                            lines.add("- " + title + ": " + trimTo(snippet, 190) + " [" + source + "]");
                        }
                    }
                }
            } catch (Exception e) {
                log.debug("Wikipedia context fetch skipped: {}", e.getMessage());
            }
        }

        if (lines.isEmpty()) return "";

        if (lines.size() > 3) lines = lines.subList(0, 3);
        String joined = "Research snippets:\n" + String.join("\n", lines);
        return trimTo(joined, 1200);
    }

    private JsonNode fetchJson(String url, int timeoutSec) {
        try {
            HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(timeoutSec))
                    .header("Accept", "application/json")
                    .GET()
                    .build();
            HttpResponse<String> res = WEB_HTTP.send(req, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            if (res.statusCode() >= 200 && res.statusCode() < 300) {
                return MAPPER.readTree(res.body());
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    private String stripHtml(String input) {
        if (input == null || input.isBlank()) return "";
        return input.replaceAll("<[^>]+>", "").replaceAll("\\s+", " ").trim();
    }

    private String trimTo(String input, int maxLen) {
        if (input == null) return "";
        if (input.length() <= maxLen) return input;
        return input.substring(0, Math.max(0, maxLen - 1)).trim() + "…";
    }

    private Flux<String> streamOpenAiWithFallback(WebClient client,
                                                   Map<String, Object> requestBody,
                                                   String requestedModel) {
        // If requested model is unavailable, retry once with a known-safe fallback model.
        return streamTokens(client, requestBody)
            .onErrorResume(WebClientResponseException.class, ex -> {
                String body = ex.getResponseBodyAsString();
                boolean looksLikeModelError = ex.getStatusCode().is4xxClientError()
                    && body != null
                    && body.toLowerCase(Locale.ROOT).contains("model");
                if (looksLikeModelError && !OPENAI_FALLBACK_MODEL.equals(requestedModel)) {
                    log.warn("OpenAI model '{}' unavailable. Retrying with '{}'", requestedModel, OPENAI_FALLBACK_MODEL);
                    Map<String, Object> retryBody = new LinkedHashMap<>(requestBody);
                    retryBody.put("model", OPENAI_FALLBACK_MODEL);
                    return streamTokens(client, retryBody);
                }
                return Flux.error(ex);
            });
    }

    private JsonNode requestTitle(List<Map<String, Object>> messages, String model) {
        try {
            Map<String, Object> requestBody = Map.of(
                "model", model,
                "messages", messages,
                "max_completion_tokens", 15,
                "temperature", 0.3
            );
            return openAiClient.post()
                .uri("/chat/completions")
                .bodyValue(requestBody)
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();
        } catch (WebClientResponseException ex) {
            String body = ex.getResponseBodyAsString();
            boolean looksLikeModelError = ex.getStatusCode().is4xxClientError()
                && body != null
                && body.toLowerCase(Locale.ROOT).contains("model");
            if (looksLikeModelError && !OPENAI_FALLBACK_MODEL.equals(model)) {
                log.warn("Title model '{}' unavailable. Will retry with '{}'", model, OPENAI_FALLBACK_MODEL);
                return null;
            }
            throw ex;
        }
    }

    private Flux<String> streamTokens(WebClient client, Map<String, Object> requestBody) {
        // OpenAI emits SSE frames; parse each frame and extract delta.content text chunks.
        return client.post()
            .uri("/chat/completions")
            .accept(MediaType.TEXT_EVENT_STREAM)
            .bodyValue(requestBody)
            .retrieve()
            .bodyToFlux(DataBuffer.class)
            .map(this::toUtf8)
            .transform(this::splitSseLines)
            .filter(line -> !line.isBlank())
            .concatMap(line -> {
                String data = line.startsWith("data: ") ? line.substring(6).trim() : line.trim();
                if ("[DONE]".equals(data)) return Flux.empty();
                try {
                    JsonNode node = MAPPER.readTree(data);
                    JsonNode choices = node.path("choices");
                    if (choices.isArray() && choices.size() > 0) {
                        JsonNode content = choices.get(0).path("delta").path("content");
                        if (!content.isMissingNode() && !content.isNull()) {
                            String text = content.asText();
                            if (!text.isEmpty()) return Flux.just(text);
                        }
                    }
                } catch (Exception ignored) {
                    // Skip malformed SSE chunk
                }
                return Flux.empty();
            });
    }

    private String toUtf8(DataBuffer buffer) {
        byte[] bytes = new byte[buffer.readableByteCount()];
        buffer.read(bytes);
        DataBufferUtils.release(buffer);
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private Flux<String> splitSseLines(Flux<String> chunks) {
        // Reassembles arbitrary network chunks into complete line-delimited SSE records.
        return Flux.create(sink -> {
            StringBuilder pending = new StringBuilder();
            chunks.subscribe(
                chunk -> {
                    pending.append(chunk);
                    int idx;
                    while ((idx = indexOfLineBreak(pending)) >= 0) {
                        String line = pending.substring(0, idx);
                        int consume = 1;
                        if (pending.charAt(idx) == '\r' && idx + 1 < pending.length() && pending.charAt(idx + 1) == '\n') {
                            consume = 2;
                        }
                        pending.delete(0, idx + consume);
                        sink.next(line);
                    }
                },
                sink::error,
                () -> {
                    if (pending.length() > 0) {
                        sink.next(pending.toString());
                    }
                    sink.complete();
                }
            );
        });
    }

    private int indexOfLineBreak(StringBuilder sb) {
        for (int i = 0; i < sb.length(); i++) {
            char c = sb.charAt(i);
            if (c == '\n' || c == '\r') return i;
        }
        return -1;
    }
}
