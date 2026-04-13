import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

// Feature: scientific calculator with local evaluation + server history sync.
class CalculatorScreen extends StatefulWidget {
  final VoidCallback? onSwitch;

  const CalculatorScreen({super.key, this.onSwitch});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen>
    with SingleTickerProviderStateMixin {
  // ── Expression-based state ─────────────────────────────
  String _expression = ''; // Display-friendly full expression (top)
  String _result = ''; // Live/final result (bottom, pink)
  bool _isResult = false; // true after = is pressed

  bool _isScientific = false;
  bool _isRad = true;
  bool _isInverse = false;
  bool _showHistory = false;

  List<CalcHistoryItem> _history = [];
  bool _historyLoading = false;
  DateTime? _filterDate;

  final _api = ApiService();
  late final AnimationController _displayAnim;
  Timer? _autoSaveDebounce;
  String? _lastSavedKey;
  DateTime? _lastSavedAt;

  @override
  void initState() {
    super.initState();
    _displayAnim = AnimationController(vsync: this, duration: 150.ms);
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    _displayAnim.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;
    setState(() => _historyLoading = true);
    try {
      final items = await _api.getCalcHistory(date: _filterDate);
      if (mounted) setState(() => _history = items);
    } catch (_) {}
    if (mounted) setState(() => _historyLoading = false);
  }

  void _animateDisplay() => _displayAnim.forward(from: 0);

  // ── Input handlers ─────────────────────────────────────

  void _handleNumber(String s) {
    HapticFeedback.lightImpact();
    setState(() {
      if (_isResult) {
        // After =: start fresh (unless appending to parens context)
        _expression = s;
        _isResult = false;
      } else {
        _expression += s;
      }
      _result = _computeLive();
    });
    _queueAutoSave();
  }

  void _handleOperator(String op) {
    HapticFeedback.mediumImpact();

    // ── Scientific functions → append notation ──────────
    const sciFuncs = [
      'sin',
      'cos',
      'tan',
      'sqrt',
      'cbrt',
      'ln',
      'log',
      'exp',
      'pow10',
      'asin',
      'acos',
      'atan'
    ];
    if (sciFuncs.contains(op)) {
      final label = switch (op) {
        'sqrt' => '√(',
        'cbrt' => '∛(',
        'exp' => 'e^(',
        'pow10' => '10^(',
        _ => '$op(',
      };
      setState(() {
        if (_isResult) {
          _expression = label;
          _isResult = false;
        } else {
          _expression += label;
        }
        _result = _computeLive();
      });
      _queueAutoSave();
      return;
    }

    // ── Factorial ───────────────────────────────────────
    if (op == '!') {
      setState(() {
        if (_isResult) {
          final carry = (_result.isNotEmpty &&
                  _result != 'Error' &&
                  _result != 'Domain error')
              ? _result
              : _expression;
          _expression = carry.replaceAll(',', '');
          _isResult = false;
        }
        _expression += '!';
        _result = _computeLive();
      });
      _queueAutoSave();
      return;
    }

    // ── Percent ─────────────────────────────────────────
    if (op == '%') {
      setState(() {
        if (_isResult) {
          final carry = (_result.isNotEmpty &&
                  _result != 'Error' &&
                  _result != 'Domain error')
              ? _result
              : _expression;
          _expression = carry.replaceAll(',', '');
          _isResult = false;
        }
        _expression += '%';
        _result = _computeLive();
      });
      _queueAutoSave();
      return;
    }

    // ── Arithmetic operators ─────────────────────────────
    final displayOp =
        {'*': '×', '/': '÷', '**': '^', '+': '+', '-': '-'}[op] ?? op;
    setState(() {
      if (_isResult) {
        final carry = (_result.isNotEmpty &&
                _result != 'Error' &&
                _result != 'Domain error')
            ? _result
            : _expression;
        if (carry.isNotEmpty) {
          final rawCarry = carry.replaceAll(',', '');
          _expression = '$rawCarry$displayOp';
          _isResult = false;
        }
      } else if (_expression.isEmpty) {
        // Nothing yet — ignore
      } else {
        // Replace trailing operator if user presses another
        final last = _expression[_expression.length - 1];
        if ('×÷+-^'.contains(last)) {
          _expression =
              _expression.substring(0, _expression.length - 1) + displayOp;
        } else {
          _expression += displayOp;
        }
      }
      _result = _computeLive();
    });
    _queueAutoSave();
  }

  void _handleParenthesis() {
    HapticFeedback.lightImpact();
    final opens = '('.allMatches(_expression).length;
    final closes = ')'.allMatches(_expression).length;
    final last =
        _expression.isNotEmpty ? _expression[_expression.length - 1] : '';
    final endsWithDigitOrClose = RegExp(r'[\d.)]').hasMatch(last);
    setState(() {
      if (_isResult) {
        _expression = '(';
        _isResult = false;
      } else if (opens > closes && endsWithDigitOrClose) {
        _expression += ')';
      } else {
        _expression += '(';
      }
      _result = _computeLive();
    });
    _queueAutoSave();
  }

  Future<void> _calculate() async {
    HapticFeedback.heavyImpact();
    if (_expression.isEmpty) return;
    try {
      final raw = _expression
          .replaceAll('×', '*')
          .replaceAll('÷', '/')
          .replaceAll('^', '**');
      // Auto-close unclosed parens
      final opens = '('.allMatches(raw).length;
      final closes = ')'.allMatches(raw).length;
      var toEval = raw + ')' * (opens - closes);
      toEval = _preprocessExpr(toEval);
      if (toEval.isEmpty) return;

      final resVal = _evalExpression(toEval);
      final finalResult = _formatResult(resVal);
      final equationToSave = _expression;
      _animateDisplay();
      setState(() {
        _result = finalResult;
        _isResult = true;
      });
      await _saveHistoryIfNeeded(equationToSave, finalResult);
    } catch (e) {
      final msg = e.toString();
      final label = (msg.contains('Domain') || msg.contains('Division by zero'))
          ? 'Domain error'
          : 'Error';
      setState(() {
        _result = label;
        _isResult = true;
      });
    }
  }

  void _clear() {
    HapticFeedback.lightImpact();
    setState(() {
      _expression = '';
      _result = '';
      _isResult = false;
    });
    _autoSaveDebounce?.cancel();
  }

  void _backspace() {
    HapticFeedback.lightImpact();
    if (_isResult) {
      setState(() {
        _result = '';
        _isResult = false;
      });
      return;
    }
    setState(() {
      if (_expression.isNotEmpty) {
        // Smart remove: wipe whole function name if cursor is right after 'sin(' etc.
        final funcMatch = RegExp(
                r'(sin|cos|tan|√|∛|sqrt|cbrt|ln|log|exp|pow10|asin|acos|atan)\($')
            .firstMatch(_expression);
        if (funcMatch != null) {
          _expression = _expression.substring(0, funcMatch.start);
        } else {
          _expression = _expression.substring(0, _expression.length - 1);
        }
      }
      _result = _computeLive();
    });
    _queueAutoSave();
  }

  /// Compute a live preview — shows domain errors, silently drops syntax errors.
  String _computeLive() {
    if (_expression.isEmpty) return '';
    try {
      var toEval = _expression
          .replaceAll('\u00d7', '*')
          .replaceAll('\u00f7', '/')
          .replaceAll('^', '**');
      final opens = '('.allMatches(toEval).length;
      final closes = ')'.allMatches(toEval).length;
      toEval += ')' * (opens - closes);
      final processed = _preprocessExpr(toEval);
      if (processed.isEmpty) return '';
      final r = _evalExpression(processed);
      return _formatResult(r);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('Domain') || msg.contains('Division by zero')) {
        return 'Domain error';
      }
      return ''; // Incomplete / syntax error — silent
    }
  }

  /// Preprocess: sanitise symbols, handle √/!, add implicit *, strip trailing ops
  String _preprocessExpr(String expr) {
    var e = expr
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(',', '') // strip thousand-separators from formatted results
        .replaceAll('\u00d7', '*')
        .replaceAll('\u00f7', '/')
        .replaceAll('\u2212', '-')
        .replaceAll('√', 'sqrt')
        .replaceAll('∛', 'cbrt');
    // Factorial: expand n! inline
    e = e.replaceAllMapped(RegExp(r'(\d+)!'), (m) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      if (n < 0 || n > 20) {
        throw Exception('Domain error: n! requires 0≤n≤20');
      }
      int f = 1;
      for (int i = 1; i <= n; i++) {
        f *= i;
      }
      return f.toString();
    });
    // Allow shorthand function calls like sin30, log100, sqrt9
    e = e.replaceAllMapped(
      RegExp(
        r'\b(asin|acos|atan|sin|cos|tan|sqrt|cbrt|ln|log|exp|pow10)\s*(-?(?:\d+\.?\d*|\.\d+)|pi|e)\b',
      ),
      (m) => '${m.group(1)}(${m.group(2)})',
    );
    // Implicit multiplication for cases like 2(3), 9sin(...), pi(2), (2+1)cos(...)
    e = e.replaceAllMapped(RegExp(r'([\d)])\('), (m) => '${m.group(1)}*(');
    e = e.replaceAllMapped(
      RegExp(
          r'([\d)])(?=(asin|acos|atan|sin|cos|tan|sqrt|cbrt|ln|log|exp|pow10|pi|e)\b)'),
      (m) => '${m.group(1)}*',
    );
    e = e.replaceAllMapped(RegExp(r'(pi|e)\('), (m) => '${m.group(1)}*(');
    e = e.replaceAllMapped(
      RegExp(
          r'(pi|e)(?=(asin|acos|atan|sin|cos|tan|sqrt|cbrt|ln|log|exp|pow10|pi|e)\b)'),
      (m) => '${m.group(1)}*',
    );
    e = e.replaceAllMapped(RegExp(r'pi(?=[\d.])'), (_) => 'pi*');
    e = e.replaceAllMapped(RegExp(r'\)([\d.(])'), (m) => ')*${m.group(1)}');
    e = e.replaceAllMapped(
      RegExp(
          r'\)(?=(asin|acos|atan|sin|cos|tan|sqrt|cbrt|ln|log|exp|pow10|pi|e)\b)'),
      (_) => ')*',
    );
    e = e.replaceAllMapped(
      RegExp(
          r'([%!])(?=[\d.(]|asin|acos|atan|sin|cos|tan|sqrt|cbrt|ln|log|exp|pow10|pi|e)'),
      (m) => '${m.group(1)}*',
    );
    // Strip trailing operator
    e = e.replaceAll(RegExp(r'[+\-*/]+\s*$'), '').trim();
    return e;
  }

  /// Recursive evaluator — correct precedence: parens > +/- > unary- > */ > **
  double _evalExpression(String expr) {
    expr = expr.trim();
    if (expr.isEmpty) throw Exception('Empty');

    // 1. Strip matching outer parens
    if (expr.startsWith('(') && expr.endsWith(')')) {
      int depth = 0;
      bool balanced = true;
      for (int i = 0; i < expr.length - 1; i++) {
        if (expr[i] == '(') {
          depth++;
        } else if (expr[i] == ')') {
          depth--;
        }
        if (depth == 0) {
          balanced = false;
          break;
        }
      }
      if (balanced) return _evalExpression(expr.substring(1, expr.length - 1));
    }

    // 2. +/- at top level (lowest precedence)
    for (int i = expr.length - 1; i > 0; i--) {
      final ch = expr[i];
      if (ch == '+' || ch == '-') {
        final prev = expr[i - 1];
        if (prev == 'e' || prev == 'E') continue;
        if ('+-*/('.contains(prev)) continue;
        int depth = 0;
        for (int j = 0; j < i; j++) {
          if (expr[j] == '(') {
            depth++;
          } else if (expr[j] == ')') {
            depth--;
          }
        }
        if (depth != 0) continue;
        final leftExpr = expr.substring(0, i);
        final rightExpr = expr.substring(i + 1).trim();
        final leftVal = _evalExpression(leftExpr);

        // Advanced percent semantics: a ± b% -> a ± (a*b/100)
        if (rightExpr.endsWith('%') && rightExpr.length > 1) {
          final pctExpr = rightExpr.substring(0, rightExpr.length - 1);
          final pctVal = _evalExpression(pctExpr);
          final delta = leftVal * (pctVal / 100.0);
          return ch == '+' ? leftVal + delta : leftVal - delta;
        }

        final rightVal = _evalExpression(rightExpr);
        return ch == '+' ? leftVal + rightVal : leftVal - rightVal;
      }
    }

    // 3. Unary minus
    if (expr.startsWith('-')) return -_evalExpression(expr.substring(1));

    // 4. * and / (medium precedence)
    for (int i = expr.length - 1; i >= 0; i--) {
      final ch = expr[i];
      if (ch == '*' || ch == '/') {
        if (ch == '*' && i > 0 && expr[i - 1] == '*') {
          i--;
          continue;
        }
        if (ch == '*' && i < expr.length - 1 && expr[i + 1] == '*') continue;
        int depth = 0;
        for (int j = 0; j < i; j++) {
          if (expr[j] == '(') {
            depth++;
          } else if (expr[j] == ')') {
            depth--;
          }
        }
        if (depth != 0) continue;
        final left = _evalExpression(expr.substring(0, i));
        final right = _evalExpression(expr.substring(i + 1));
        if (ch == '/') {
          if (right == 0) throw Exception('Division by zero');
          return left / right;
        }
        return left * right;
      }
    }

    // 5. Postfix operators: % and !
    if (expr.endsWith('%')) {
      return _evalExpression(expr.substring(0, expr.length - 1)) / 100;
    }
    if (expr.endsWith('!')) {
      final raw = _evalExpression(expr.substring(0, expr.length - 1));
      final n = raw.round();
      if ((raw - n).abs() > 1e-10 || n < 0 || n > 20) {
        throw Exception('Domain error: n! requires 0≤n≤20');
      }
      return _factorial(n).toDouble();
    }

    // 6. ** power (highest binary precedence, right-associative)
    final powIdx = _findOperatorLTR(expr, '**');
    if (powIdx >= 0) {
      return math
          .pow(
            _evalExpression(expr.substring(0, powIdx)),
            _evalExpression(expr.substring(powIdx + 2)),
          )
          .toDouble();
    }

    // 7. Named function calls: sin(...), cos(...), asin(...), sqrt(...), etc.
    final fnMatch = RegExp(
      r'^(asin|acos|atan|sin|cos|tan|sqrt|cbrt|ln|log|exp|pow10)\((.+)\)$',
    ).firstMatch(expr);
    if (fnMatch != null) {
      final fn = fnMatch.group(1)!;
      final argStr = fnMatch.group(2)!;
      final arg = _evalExpression(argStr);
      return _applyFunction(fn, arg);
    }

    // 8. Constants and number literals
    if (expr == 'pi' || expr == '\u03c0') return math.pi;
    if (expr == 'e') return math.e;
    final n = double.tryParse(expr);
    if (n != null) return n;

    throw Exception('Cannot evaluate: $expr');
  }

  /// Apply a named math function using current Rad/Deg mode, with domain checks.
  double _applyFunction(String fn, double arg) {
    // Angles: in deg mode convert input to radians for trig; for inverse, output to degrees
    final toRad = _isRad ? 1.0 : math.pi / 180.0;
    final toDeg = _isRad ? 1.0 : 180.0 / math.pi;
    switch (fn) {
      case 'sin':
        return math.sin(arg * toRad);
      case 'cos':
        return math.cos(arg * toRad);
      case 'tan':
        final t = math.tan(arg * toRad);
        if (t.isInfinite || t.isNaN) {
          throw Exception('Domain error: tan undefined here');
        }
        return t;
      case 'asin':
        if (arg < -1 || arg > 1) {
          throw Exception('Domain error: asin needs [-1,1]');
        }
        return math.asin(arg) * toDeg;
      case 'acos':
        if (arg < -1 || arg > 1) {
          throw Exception('Domain error: acos needs [-1,1]');
        }
        return math.acos(arg) * toDeg;
      case 'atan':
        return math.atan(arg) * toDeg;
      case 'sqrt':
        if (arg < 0) {
          throw Exception('Domain error: sqrt of negative');
        }
        return math.sqrt(arg);
      case 'cbrt':
        return arg < 0
            ? -math.pow(-arg, 1 / 3).toDouble()
            : math.pow(arg, 1 / 3).toDouble();
      case 'ln':
        if (arg <= 0) {
          throw Exception('Domain error: ln of non-positive');
        }
        return math.log(arg);
      case 'log':
        if (arg <= 0) {
          throw Exception('Domain error: log of non-positive');
        }
        return math.log(arg) / math.ln10;
      case 'exp':
        return math.exp(arg);
      case 'pow10':
        return math.pow(10, arg).toDouble();
      default:
        throw Exception('Unknown function: $fn');
    }
  }

  int _findOperatorLTR(String expr, String op) {
    int depth = 0;
    for (int i = 0; i <= expr.length - op.length; i++) {
      if (expr[i] == '(') {
        depth++;
      } else if (expr[i] == ')') {
        depth--;
      } else if (depth == 0 && expr.startsWith(op, i)) {
        return i;
      }
    }
    return -1;
  }

  int _factorial(int n) {
    int f = 1;
    for (int i = 1; i <= n; i++) {
      f *= i;
    }
    return f;
  }

  String _formatResult(double r) {
    if (r.isNaN || r.isInfinite) return 'Error';
    if (r == r.roundToDouble() && r.abs() < 1e15) {
      // Format integers with thousand-separators (e.g. 134,217,728)
      final n = r.toInt();
      if (n.abs() >= 1000) {
        return NumberFormat('#,##0').format(n);
      }
      return n.toString();
    }
    // Trim trailing zeros after decimal
    return double.parse(r.toStringAsFixed(10)).toString();
  }

  void _queueAutoSave() {
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      if (!_canAutoSave(_expression, _result)) return;
      _saveHistoryIfNeeded(_expression, _result);
    });
  }

  bool _canAutoSave(String equation, String result) {
    if (equation.trim().isEmpty) return false;
    if (result.trim().isEmpty) return false;
    if (result == 'Error' || result == 'Domain error') return false;
    if (!_hasMeaningfulOperation(equation)) return false;
    final trimmed = equation.trim();
    final endsComplete = RegExp(r'[\d)!%]$').hasMatch(trimmed);
    return endsComplete;
  }

  bool _hasMeaningfulOperation(String equation) {
    final compact = equation.replaceAll(',', '').replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return false;

    // Plain literal values should not be stored as "x = x" history rows.
    if (RegExp(r'^(?:-)?(?:\d+\.?\d*|\.\d+)$').hasMatch(compact)) {
      return false;
    }
    if (RegExp(r'^(?:-)?(?:pi|e)$', caseSensitive: false).hasMatch(compact)) {
      return false;
    }

    // Any operator/function/parenthesized expression counts as a meaningful calculation.
    return RegExp(
            r'[+×÷*/^%!()]|asin|acos|atan|sin|cos|tan|sqrt|cbrt|ln|log|exp|pow10')
        .hasMatch(compact);
  }

  Future<void> _saveHistoryIfNeeded(String equation, String result) async {
    final normalizedEq = equation.replaceAll(RegExp(r'\s+'), ' ').trim();
    final normalizedRes = result.replaceAll(',', '').trim();
    if (normalizedEq.isEmpty || normalizedRes.isEmpty) return;
    if (!_hasMeaningfulOperation(normalizedEq)) return;

    final key = '$normalizedEq==$normalizedRes';
    final now = DateTime.now();
    if (_lastSavedKey == key &&
        _lastSavedAt != null &&
        now.difference(_lastSavedAt!) < const Duration(seconds: 15)) {
      return;
    }

    try {
      await _api.saveCalcHistory(normalizedEq, normalizedRes);
      _lastSavedKey = key;
      _lastSavedAt = now;
    } catch (_) {}
  }

  // _clear, _backspace, _handleParenthesis defined above in new expression model

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenHeight = MediaQuery.of(context).size.height;
    final double displayHeight = _isScientific
        ? (screenHeight * 0.182).clamp(112.0, 152.0).toDouble()
        : (screenHeight * 0.265).clamp(150.0, 210.0).toDouble();

    return Stack(
      children: [
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 72, 10, 4),
            child: Column(
              children: [
                // Display
                AnimatedContainer(
                  duration: 260.ms,
                  curve: Curves.easeOutCubic,
                  height: displayHeight,
                  child: _DisplayPanel(
                    expression: _expression,
                    result: _result,
                    isResult: _isResult,
                    isDark: isDark,
                    animController: _displayAnim,
                  ),
                ),

                const SizedBox(height: 6),

                // Sci toggle (left-aligned) with animated chevron
                Row(
                  children: [
                    _SmallButton(
                      isDark: isDark,
                      isActive: _isScientific,
                      onTap: () => setState(() {
                        _isScientific = !_isScientific;
                        _isInverse = false;
                      }),
                    ),
                  ],
                ),

                const SizedBox(height: 6),

                // Scientific Row - 3-row × 4-col grid
                AnimatedContainer(
                  duration: 300.ms,
                  curve: Curves.easeOutCubic,
                  height: _isScientific ? 138 : 0,
                  child: _isScientific
                      ? _ScientificRow(
                          isDark: isDark,
                          isRad: _isRad,
                          isInverse: _isInverse,
                          onOp: _handleOperator,
                          onNum: _handleNumber,
                          onToggleRad: () => setState(() {
                            _isRad = !_isRad;
                            // Immediately recompute so result updates without re-typing
                            _result = _computeLive();
                          }),
                          onToggleInverse: () => setState(() {
                            _isInverse = !_isInverse;
                          }),
                        )
                      : const SizedBox.shrink(),
                ),

                const SizedBox(height: 6),

                // Main Grid
                Expanded(
                  child: _ButtonGrid(
                    isDark: isDark,
                    onNumber: _handleNumber,
                    onOperator: _handleOperator,
                    onCalculate: _calculate,
                    onClear: _clear,
                    onBackspace: _backspace,
                    onParenthesis: _handleParenthesis,
                  ),
                ),
              ],
            ),
          ),
        ),

        // History icon — pinned to top-left in the AppBar area
        Positioned(
          top: MediaQuery.of(context).padding.top + 14,
          left: 14,
          child: Row(
            children: [
              GestureDetector(
                onTap: () {
                  setState(() => _showHistory = true);
                  _loadHistory();
                },
                child: Icon(
                  Icons.history_rounded,
                  size: 30,
                  color:
                      isDark ? AuricTheme.darkSubtext : AuricTheme.lightSubtext,
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: widget.onSwitch,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withOpacity(0.08)
                        : Colors.black.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: (isDark ? Colors.white : Colors.black)
                          .withOpacity(0.1),
                    ),
                  ),
                  child: Text(
                    'Calculator',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color:
                          isDark ? AuricTheme.darkText : AuricTheme.lightText,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // History Drawer
        if (_showHistory)
          _HistoryDrawer(
            isDark: isDark,
            history: _history,
            isLoading: _historyLoading,
            filterDate: _filterDate,
            onClose: () => setState(() => _showHistory = false),
            onDateChange: (d) {
              setState(() => _filterDate = d);
              _loadHistory();
            },
            onUseResult: (result) {
              setState(() {
                // Strip commas before putting back into expression
                _expression = result.replaceAll(',', '');
                _result = '';
                _isResult = false;
                _showHistory = false;
              });
            },
          ),
      ],
    );
  }
}

// ─── Display ──────────────────────────────────────────────

class _DisplayPanel extends StatelessWidget {
  final String expression;
  final String result;
  final bool isResult;
  final bool isDark;
  final AnimationController animController;

  const _DisplayPanel({
    required this.expression,
    required this.result,
    required this.isResult,
    required this.isDark,
    required this.animController,
  });

  @override
  Widget build(BuildContext context) {
    final displayExpression = isResult ? '' : expression;

    // Expression font: shrinks for long expressions
    final exprLen = displayExpression.length;
    final exprFontSize = exprLen > 20
        ? 22.0
        : exprLen > 12
            ? 27.0
            : 34.0;

    // Result font: large and prominent, shrinks if too long
    final resLen = result.length;
    final resFontSize = resLen > 14
        ? 32.0
        : resLen > 9
            ? 42.0
            : 54.0;

    final exprColor = isDark
        ? Colors.white.withOpacity(0.75)
        : Colors.black.withOpacity(0.65);
    final resultColor =
        isDark ? AuricTheme.brandBlueLight : AuricTheme.brandBlueDark;
    final pulseScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.045)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 45,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.045, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 55,
      ),
    ]).animate(animController);
    final pulseGlow = Tween<double>(begin: 0, end: 12).animate(
      CurvedAnimation(parent: animController, curve: Curves.easeOut),
    );

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 120, maxHeight: 230),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── TOP: full expression ───────────────────────
          AnimatedDefaultTextStyle(
            duration: 120.ms,
            style: TextStyle(
              fontSize: exprFontSize,
              fontWeight: FontWeight.w500,
              color: exprColor,
              letterSpacing: -0.5,
            ),
            child: Text(
              displayExpression,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(height: 6),
          // ── BOTTOM: live result (pink) ─────────────────
          AnimatedBuilder(
            animation: animController,
            builder: (context, child) {
              final showPulse = isResult && result.isNotEmpty;
              return Transform.scale(
                scale: showPulse ? pulseScale.value : 1.0,
                alignment: Alignment.centerRight,
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    shadows: showPulse
                        ? [
                            Shadow(
                              color: resultColor.withOpacity(0.35),
                              blurRadius: pulseGlow.value,
                            ),
                          ]
                        : null,
                  ),
                  child: child!,
                ),
              );
            },
            child: AnimatedDefaultTextStyle(
              duration: 150.ms,
              style: TextStyle(
                fontSize: result.isEmpty ? 0.1 : resFontSize,
                fontWeight: FontWeight.w700,
                color: (result == 'Error' || result == 'Domain error')
                    ? Colors.redAccent
                    : resultColor,
                letterSpacing: -1,
              ),
              child: Text(
                result,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Scientific Row ────────────────────────────────────────

class _ScientificRow extends StatelessWidget {
  final bool isDark;
  final bool isRad;
  final bool isInverse;
  final Function(String) onOp;
  final Function(String) onNum;
  final VoidCallback onToggleRad;
  final VoidCallback onToggleInverse;

  const _ScientificRow({
    required this.isDark,
    required this.isRad,
    required this.isInverse,
    required this.onOp,
    required this.onNum,
    required this.onToggleRad,
    required this.onToggleInverse,
  });

  @override
  Widget build(BuildContext context) {
    // 3 rows × 4 cols matching reference layout
    return GridView.count(
      crossAxisCount: 4,
      crossAxisSpacing: 4,
      mainAxisSpacing: 4,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.35,
      children: [
        // Row 1: √  π  ^  !
        _CalcButton(
            label: isInverse ? '∛' : '√',
            onTap: () => onOp(isInverse ? 'cbrt' : 'sqrt'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
        _CalcButton(
            label: 'π',
            onTap: () => onNum('3.14159265'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
        _CalcButton(
            label: '^',
            onTap: () => onOp('**'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
        _CalcButton(
            label: '!',
            onTap: () => onOp('!'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
        // Row 2: Rad/Deg  sin/asin  cos/acos  tan/atan
        _CalcButton(
          label: isRad ? 'Rad' : 'Deg',
          onTap: onToggleRad,
          variant: _ButtonVariant.sciToggle,
          isDark: isDark,
          isAccent: true,
        ),
        _CalcButton(
            label: isInverse ? 'sin⁻¹' : 'sin',
            onTap: () => onOp(isInverse ? 'asin' : 'sin'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
        _CalcButton(
            label: isInverse ? 'cos⁻¹' : 'cos',
            onTap: () => onOp(isInverse ? 'acos' : 'cos'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
        _CalcButton(
            label: isInverse ? 'tan⁻¹' : 'tan',
            onTap: () => onOp(isInverse ? 'atan' : 'tan'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
        // Row 3: Inv  e  ln  log
        _CalcButton(
          label: 'Inv',
          onTap: onToggleInverse,
          variant: _ButtonVariant.sciToggle,
          isDark: isDark,
          isAccent: isInverse,
        ),
        _CalcButton(
            label: 'e',
            onTap: () => onNum('2.71828182'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
        _CalcButton(
            label: isInverse ? 'eˣ' : 'ln',
            onTap: () => onOp(isInverse ? 'exp' : 'ln'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
        _CalcButton(
            label: isInverse ? '10ˣ' : 'log',
            onTap: () => onOp(isInverse ? 'pow10' : 'log'),
            variant: _ButtonVariant.scientific,
            isDark: isDark),
      ],
    );
  }
}

// ─── Main Button Grid ──────────────────────────────────────

enum _ButtonVariant { number, operator, action, equal, scientific, sciToggle }

class _ButtonGrid extends StatelessWidget {
  final bool isDark;
  final Function(String) onNumber;
  final Function(String) onOperator;
  final VoidCallback onCalculate;
  final VoidCallback onClear;
  final VoidCallback onBackspace;
  final VoidCallback onParenthesis;

  const _ButtonGrid({
    required this.isDark,
    required this.onNumber,
    required this.onOperator,
    required this.onCalculate,
    required this.onClear,
    required this.onBackspace,
    required this.onParenthesis,
  });

  @override
  Widget build(BuildContext context) {
    // Use LayoutBuilder so buttons always fill the available space perfectly
    return LayoutBuilder(builder: (context, constraints) {
      const int rows = 5;
      const int cols = 4;
      const double spacing = 5;
      // Compute exact button height to fill the grid without overflow
      final double btnHeight =
          (constraints.maxHeight - spacing * (rows - 1)) / rows;
      // Keep buttons slightly wider square-ish but honour the computed height
      final double aspectRatio =
          (constraints.maxWidth - spacing * (cols - 1)) / cols / btnHeight;

      return GridView.count(
        crossAxisCount: cols,
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: aspectRatio,
        children: [
          _CalcButton(
              label: 'AC',
              onTap: onClear,
              variant: _ButtonVariant.action,
              isDark: isDark,
              isAccent: true),
          _CalcButton(
              label: '( )',
              onTap: onParenthesis,
              variant: _ButtonVariant.operator,
              isDark: isDark),
          _CalcButton(
              label: '%',
              onTap: () => onOperator('%'),
              variant: _ButtonVariant.operator,
              isDark: isDark),
          _CalcButton(
              label: '÷',
              onTap: () => onOperator('/'),
              variant: _ButtonVariant.operator,
              isDark: isDark),
          _CalcButton(label: '7', onTap: () => onNumber('7'), isDark: isDark),
          _CalcButton(label: '8', onTap: () => onNumber('8'), isDark: isDark),
          _CalcButton(label: '9', onTap: () => onNumber('9'), isDark: isDark),
          _CalcButton(
              label: '×',
              onTap: () => onOperator('*'),
              variant: _ButtonVariant.operator,
              isDark: isDark),
          _CalcButton(label: '4', onTap: () => onNumber('4'), isDark: isDark),
          _CalcButton(label: '5', onTap: () => onNumber('5'), isDark: isDark),
          _CalcButton(label: '6', onTap: () => onNumber('6'), isDark: isDark),
          _CalcButton(
              label: '−',
              onTap: () => onOperator('-'),
              variant: _ButtonVariant.operator,
              isDark: isDark),
          _CalcButton(label: '1', onTap: () => onNumber('1'), isDark: isDark),
          _CalcButton(label: '2', onTap: () => onNumber('2'), isDark: isDark),
          _CalcButton(label: '3', onTap: () => onNumber('3'), isDark: isDark),
          _CalcButton(
              label: '+',
              onTap: () => onOperator('+'),
              variant: _ButtonVariant.operator,
              isDark: isDark),
          _CalcButton(label: '0', onTap: () => onNumber('0'), isDark: isDark),
          _CalcButton(label: '.', onTap: () => onNumber('.'), isDark: isDark),
          _CalcButton(
            label: '⌫',
            onTap: onBackspace,
            variant: _ButtonVariant.action,
            isDark: isDark,
            icon: Icons.backspace_outlined,
          ),
          _CalcButton(
              label: '=',
              onTap: onCalculate,
              variant: _ButtonVariant.equal,
              isDark: isDark),
        ],
      );
    });
  }
}

class _CalcButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final _ButtonVariant variant;
  final bool isDark;
  final bool isAccent;
  final IconData? icon;

  const _CalcButton({
    required this.label,
    required this.onTap,
    this.variant = _ButtonVariant.number,
    required this.isDark,
    this.isAccent = false,
    this.icon,
  });

  @override
  State<_CalcButton> createState() => _CalcButtonState();
}

class _CalcButtonState extends State<_CalcButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: 80.ms);
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.92)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color bg, textColor;

    switch (widget.variant) {
      case _ButtonVariant.equal:
        bg = AuricTheme.brandBlue;
        textColor = Colors.white;
        break;
      case _ButtonVariant.operator:
        bg = widget.isDark
            ? AuricTheme.brandBlue.withOpacity(0.18)
            : AuricTheme.brandBlue.withOpacity(0.12);
        textColor = AuricTheme.brandBlue;
        break;
      case _ButtonVariant.action:
        if (widget.isAccent) {
          bg = AuricTheme.brandBlueLight.withOpacity(0.25);
          textColor = AuricTheme.brandBlueLight;
        } else {
          bg = widget.isDark
              ? Colors.white.withOpacity(0.06)
              : Colors.black.withOpacity(0.06);
          textColor =
              widget.isDark ? AuricTheme.darkSubtext : AuricTheme.lightSubtext;
        }
        break;
      case _ButtonVariant.scientific:
        bg = widget.isDark
            ? Colors.white.withOpacity(0.08)
            : Colors.white.withOpacity(0.5);
        textColor = widget.isDark ? AuricTheme.darkText : AuricTheme.lightText;
        break;
      case _ButtonVariant.sciToggle:
        // Rad/Deg and Inv toggles – highlighted when isAccent (active)
        bg = widget.isAccent
            ? AuricTheme.brandBlue.withOpacity(0.35)
            : (widget.isDark
                ? Colors.white.withOpacity(0.08)
                : Colors.white.withOpacity(0.5));
        textColor = widget.isAccent
            ? AuricTheme.brandBlueLight
            : (widget.isDark ? AuricTheme.darkSubtext : AuricTheme.lightText);
        break;
      default: // number
        bg = widget.isDark
            ? Colors.white.withOpacity(0.05)
            : Colors.white.withOpacity(0.6);
        textColor = widget.isDark ? AuricTheme.darkText : AuricTheme.lightText;
    }

    // Font sizes
    final double fontSize;
    if (widget.variant == _ButtonVariant.scientific ||
        widget.variant == _ButtonVariant.sciToggle) {
      fontSize = widget.label.length > 3 ? 14 : 18;
    } else {
      fontSize = 26;
    }

    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            boxShadow: widget.variant == _ButtonVariant.equal
                ? [
                    BoxShadow(
                      color: AuricTheme.brandBlue.withOpacity(0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    )
                  ]
                : null,
            border: Border.all(
              color: (widget.isDark ? Colors.white : Colors.black)
                  .withOpacity(0.04),
            ),
          ),
          child: Center(
            child: widget.icon != null
                ? Icon(widget.icon, color: textColor, size: 22)
                : Text(
                    widget.label,
                    style: TextStyle(
                      color: textColor,
                      fontSize: fontSize,
                      fontWeight: widget.variant == _ButtonVariant.equal
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── History Drawer ────────────────────────────────────────

class _HistoryDrawer extends StatefulWidget {
  final bool isDark;
  final List<CalcHistoryItem> history;
  final bool isLoading;
  final DateTime? filterDate;
  final VoidCallback onClose;
  final Function(DateTime?) onDateChange;
  final Function(String) onUseResult;

  const _HistoryDrawer({
    required this.isDark,
    required this.history,
    required this.isLoading,
    required this.filterDate,
    required this.onClose,
    required this.onDateChange,
    required this.onUseResult,
  });

  @override
  State<_HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<_HistoryDrawer> {
  Set<int> _favIds = {};
  bool _showFavsOnly = false;

  @override
  void initState() {
    super.initState();
    _loadFavs();
  }

  Future<void> _loadFavs() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('calc_favs') ?? [];
    if (mounted) setState(() => _favIds = ids.map(int.parse).toSet());
  }

  Future<void> _toggleFav(int id) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_favIds.contains(id)) {
        _favIds.remove(id);
      } else {
        _favIds.add(id);
      }
    });
    await prefs.setStringList(
        'calc_favs', _favIds.map((e) => e.toString()).toList());
  }

  Future<void> _downloadByDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.filterDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null || !context.mounted) return;

    // Show loading snackbar
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Fetching calculations…'),
          ],
        ),
        duration: Duration(seconds: 10),
      ),
    );

    try {
      // Always fetch fresh from the API for the picked date
      final api = ApiService();
      final items = await api.getCalcHistory(date: picked);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'No calculations found for ${DateFormat('MMMM d, yyyy').format(picked)}.'),
          ),
        );
        return;
      }

      // Build the txt content
      final dateStr = DateFormat('MMMM d, yyyy').format(picked);
      final buf = StringBuffer();
      buf.writeln('Auric Calculator — Calculation History');
      buf.writeln('Date   : $dateStr');
      buf.writeln('Total  : ${items.length} calculation(s)');
      buf.writeln('=' * 45);
      buf.writeln();
      for (final item in items) {
        buf.writeln(
            'Time    : ${DateFormat('h:mm:ss a').format(item.timestamp)}');
        buf.writeln('Equation: ${item.equation}');
        buf.writeln('Result  : ${item.result}');
        if (_favIds.contains(item.id)) buf.writeln('★ Favourite');
        buf.writeln('-' * 32);
      }

      // Save to a persistent location so it's a real download
      final fileName =
          'auric_calc_${DateFormat('yyyy-MM-dd').format(picked)}.txt';
      Directory? saveDir;
      try {
        saveDir = Directory('/storage/emulated/0/Download');
        if (!await saveDir.exists()) saveDir = await getTemporaryDirectory();
      } catch (_) {
        saveDir = await getTemporaryDirectory();
      }

      final file = File('${saveDir.path}/$fileName');
      await file.writeAsString(buf.toString());

      // Share sheet — user can choose 'Save to Files', 'Drive', or any app
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/plain', name: fileName)],
        subject: 'Auric Calculator — $dateStr',
        text: 'Calculation history for $dateStr (${items.length} entries)',
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;

    List<CalcHistoryItem> displayed = widget.history;
    if (_showFavsOnly) {
      displayed = displayed.where((h) => _favIds.contains(h.id)).toList();
    }

    return Stack(
      children: [
        // Backdrop
        GestureDetector(
          onTap: widget.onClose,
          child: Container(color: Colors.black.withOpacity(0.5)),
        ),

        // Drawer
        Container(
          width: MediaQuery.of(context).size.width * 0.85,
          height: double.infinity,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111111) : Colors.white,
            border: Border(
              right: BorderSide(
                  color:
                      (isDark ? Colors.white : Colors.black).withOpacity(0.08)),
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
                  child: Row(
                    children: [
                      Icon(Icons.history_rounded,
                          color: AuricTheme.brandBlue, size: 22),
                      const SizedBox(width: 8),
                      Text('History',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(fontSize: 19)),
                      const Spacer(),
                      // Download button
                      IconButton(
                        icon: const Icon(Icons.download_rounded),
                        tooltip: 'Download by date',
                        onPressed: () => _downloadByDate(context),
                        color: AuricTheme.brandBlue,
                        iconSize: 22,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: widget.onClose,
                        color: isDark
                            ? AuricTheme.darkSubtext
                            : AuricTheme.lightSubtext,
                        iconSize: 22,
                      ),
                    ],
                  ),
                ),

                // Filter bar: Date + Favourites toggle
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                  child: Row(
                    children: [
                      // Date picker chip
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: widget.filterDate ?? DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime.now(),
                            );
                            widget.onDateChange(picked);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withOpacity(0.05)
                                  : Colors.black.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: widget.filterDate != null
                                    ? AuricTheme.brandBlue.withOpacity(0.4)
                                    : (isDark ? Colors.white : Colors.black)
                                        .withOpacity(0.08),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.calendar_today_rounded,
                                    size: 14,
                                    color: widget.filterDate != null
                                        ? AuricTheme.brandBlue
                                        : (isDark
                                            ? AuricTheme.darkSubtext
                                            : AuricTheme.lightSubtext)),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    widget.filterDate != null
                                        ? DateFormat('MMM d, yyyy')
                                            .format(widget.filterDate!)
                                        : 'Filter by date',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: widget.filterDate != null
                                          ? AuricTheme.brandBlue
                                          : (isDark
                                              ? AuricTheme.darkSubtext
                                              : AuricTheme.lightSubtext),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (widget.filterDate != null)
                                  GestureDetector(
                                    onTap: () => widget.onDateChange(null),
                                    child: Icon(Icons.close_rounded,
                                        size: 14,
                                        color: isDark
                                            ? AuricTheme.darkSubtext
                                            : AuricTheme.lightSubtext),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Favourites toggle chip
                      GestureDetector(
                        onTap: () =>
                            setState(() => _showFavsOnly = !_showFavsOnly),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: _showFavsOnly
                                ? AuricTheme.brandBlue.withOpacity(0.15)
                                : (isDark
                                    ? Colors.white.withOpacity(0.05)
                                    : Colors.black.withOpacity(0.05)),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _showFavsOnly
                                  ? AuricTheme.brandBlue.withOpacity(0.5)
                                  : (isDark ? Colors.white : Colors.black)
                                      .withOpacity(0.08),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _showFavsOnly
                                    ? Icons.star_rounded
                                    : Icons.star_outline_rounded,
                                size: 14,
                                color: _showFavsOnly
                                    ? Colors.amber
                                    : (isDark
                                        ? AuricTheme.darkSubtext
                                        : AuricTheme.lightSubtext),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Favs',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _showFavsOnly
                                      ? AuricTheme.brandBlue
                                      : (isDark
                                          ? AuricTheme.darkSubtext
                                          : AuricTheme.lightSubtext),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // List
                Expanded(
                  child: widget.isLoading
                      ? const Center(
                          child: CircularProgressIndicator(
                              color: AuricTheme.brandBlue))
                      : displayed.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _showFavsOnly
                                        ? Icons.star_outline_rounded
                                        : Icons.history_rounded,
                                    size: 40,
                                    color: isDark
                                        ? AuricTheme.darkMuted
                                        : AuricTheme.lightSubtext,
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    _showFavsOnly
                                        ? 'No favourites yet'
                                        : 'No calculations found',
                                    style: TextStyle(
                                        color: isDark
                                            ? AuricTheme.darkMuted
                                            : AuricTheme.lightSubtext),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                              itemCount: displayed.length,
                              itemBuilder: (ctx, i) {
                                final item = displayed[i];
                                final isFav = _favIds.contains(item.id);
                                return GestureDetector(
                                  onTap: () => widget.onUseResult(item.result),
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: isFav
                                          ? AuricTheme.brandBlue
                                              .withOpacity(0.06)
                                          : (isDark
                                              ? Colors.white.withOpacity(0.04)
                                              : Colors.black.withOpacity(0.03)),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: isFav
                                            ? AuricTheme.brandBlue
                                                .withOpacity(0.2)
                                            : (isDark
                                                    ? Colors.white
                                                    : Colors.black)
                                                .withOpacity(0.06),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(Icons.access_time_rounded,
                                                size: 11,
                                                color: isDark
                                                    ? AuricTheme.darkMuted
                                                    : AuricTheme.lightSubtext),
                                            const SizedBox(width: 4),
                                            Text(
                                              DateFormat('MMM d, h:mm a')
                                                  .format(item.timestamp),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: isDark
                                                    ? AuricTheme.darkMuted
                                                    : AuricTheme.lightSubtext,
                                              ),
                                            ),
                                            const Spacer(),
                                            // Favourite star
                                            GestureDetector(
                                              onTap: () => _toggleFav(item.id),
                                              child: AnimatedSwitcher(
                                                duration: const Duration(
                                                    milliseconds: 200),
                                                child: Icon(
                                                  isFav
                                                      ? Icons.star_rounded
                                                      : Icons
                                                          .star_outline_rounded,
                                                  key: ValueKey(isFav),
                                                  size: 18,
                                                  color: isFav
                                                      ? Colors.amber
                                                      : (isDark
                                                          ? AuricTheme.darkMuted
                                                          : AuricTheme
                                                              .lightSubtext),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 5),
                                        Text(
                                          item.equation,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontFamily: 'monospace',
                                            color: isDark
                                                ? AuricTheme.darkSubtext
                                                : AuricTheme.lightSubtext,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          '= ${item.result}',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: isDark
                                                ? AuricTheme.darkText
                                                : AuricTheme.lightText,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Tap to use',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: AuricTheme.brandBlue
                                                .withOpacity(0.6),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
        ).animate().slideX(
              begin: -1,
              end: 0,
              duration: 300.ms,
              curve: Curves.easeOutCubic,
            ),
      ],
    );
  }
}

class _SmallButton extends StatelessWidget {
  final bool isDark;
  final VoidCallback onTap;
  final bool isActive;

  const _SmallButton({
    required this.isDark,
    required this.onTap,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = isActive
        ? AuricTheme.brandBlue
        : (isDark ? AuricTheme.darkSubtext : AuricTheme.lightSubtext);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 46,
        height: 40,
        child: Center(
          child: AnimatedSwitcher(
            duration: 180.ms,
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: Stack(
              key: ValueKey<bool>(isActive),
              alignment: Alignment.center,
              children: [
                Transform.translate(
                  offset: const Offset(0, -5),
                  child: Transform.scale(
                    scaleY: 1.15,
                    child: Icon(
                      isActive
                          ? Icons.expand_more_rounded
                          : Icons.expand_less_rounded,
                      size: 24,
                      color: iconColor,
                    ),
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, 5),
                  child: Transform.scale(
                    scaleY: 1.15,
                    child: Icon(
                      isActive
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 24,
                      color: iconColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
