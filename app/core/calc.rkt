#lang racket/base

;; Fulcrum calculator.
;;
;; A self-contained recursive-descent parser/evaluator. `eval` and string
;; based execution are deliberately not used: the grammar below is the whole
;; trusted surface, so malformed input can only fail with a calc error, never
;; execute anything.
;;
;; Supported: + - * / % ^ (right-associative), unary minus, parentheses,
;; postfix factorial (!), constants pi/e/tau/phi, and the functions listed in
;; `functions` below. Arithmetic stays exact while it can; conversion to a
;; display string happens only at the boundary via `calculate-display`.

(require racket/contract
         racket/format
         racket/list
         racket/math
         racket/match
         racket/string)

(provide calculate
         calculate-display
         calculate-functions
         (struct-out exn:calc))

(struct exn:calc exn:fail:user ())

(define (calc-error message . args)
  (raise (exn:calc (apply format message args) (current-continuation-marks))))

(define max-expression-length 200)

(define functions
  (hasheq 'sqrt (cons 1 sqrt)
          'abs (cons 1 abs)
          'ln (cons 1 log)
          'log (cons 1 (lambda (x) (/ (log x) (log 10))))
          'log2 (cons 1 (lambda (x) (/ (log x) (log 2))))
          'exp (cons 1 exp)
          'sin (cons 1 sin)
          'cos (cons 1 cos)
          'tan (cons 1 tan)
          'asin (cons 1 asin)
          'acos (cons 1 acos)
          'atan (cons 1 atan)
          'round (cons 1 round)
          'floor (cons 1 floor)
          'ceil (cons 1 ceiling)
          'trunc (cons 1 truncate)
          'fact (cons 1 (lambda (n) (factorial (inexact->exact (floor n)))))
          'min (cons 2 min)
          'max (cons 2 max)))

(define constants
  (hasheq 'pi pi
          'e (exp 1)
          'tau (* 2 pi)
          'phi (/ (add1 (sqrt 5)) 2)))

(define (calculate-functions)
  (sort (map symbol->string (hash-keys functions)) string<?))

(define (factorial n)
  (unless (exact-integer? n)
    (calc-error "calculate: factorial needs an integer, received ~a" n))
  (unless (and (>= n 0) (<= n 170))
    (calc-error "calculate: factorial out of range: ~a" n))
  (for/fold ([acc 1]) ([i (in-range 2 (add1 n))]) (* acc i)))

;; ---- Tokenizer ----------------------------------------------------------

(struct token (kind text) #:transparent)

(define operator-chars
  (list #\+ #\- #\* #\/ #\% #\^ #\( #\) #\! #\, #\× #\÷))

;; Scientific notation: 1e2, 5E-3. The exponent must immediately follow the
;; mantissa and contain at least one digit, otherwise "e" is an identifier.
(define (scan-exponent chars)
  (define e (and (pair? chars) (car chars)))
  (if (and e (memv e '(#\e #\E)))
      (let* ([after-e (cdr chars)]
             [has-sign (and (pair? after-e) (memv (car after-e) '(#\+ #\-)))]
             [digit-start (if has-sign (cdr after-e) after-e)]
             [digits (takef digit-start char-numeric?)])
        (if (null? digits)
            (values '() chars)
            (values (cons e (append (if has-sign (list (car after-e)) '()) digits))
                    (dropf digit-start char-numeric?))))
      (values '() chars)))

(define (tokenize input)
  (when (> (string-length input) max-expression-length)
    (calc-error "calculate: expression longer than ~a characters"
                max-expression-length))
  (let loop ([chars (string->list input)] [tokens '()])
    (cond
      [(null? chars) (reverse tokens)]
      [(char-whitespace? (car chars)) (loop (cdr chars) tokens)]
      [(or (char-numeric? (car chars)) (memv (car chars) '(#\.)))
       (define-values (digits rest)
         (splitf-at chars (lambda (c) (or (char-numeric? c) (char=? c #\.)))))
       (define-values (exp-chars rest*) (scan-exponent rest))
       (loop rest*
             (cons (token 'number (list->string (append digits exp-chars)))
                   tokens))]
      [(or (char-alphabetic? (car chars)) (memv (car chars) '(#\_)))
       (define-values (ident rest)
         (splitf-at chars (lambda (c) (or (char-alphabetic? c)
                                          (char-numeric? c)
                                          (char=? c #\_)))))
       (loop rest (cons (token 'ident (list->string ident)) tokens))]
      [(memv (car chars) operator-chars)
       (define kind
         (case (car chars)
           [(#\×) 'mul]
           [(#\÷) 'div]
           [else (car chars)]))
       (loop (cdr chars) (cons (token kind (string (car chars))) tokens))]
      [else
       (calc-error "calculate: unexpected character ~a" (car chars))])))

;; ---- Parser (expr → term → unary → power → atom) ------------------------

(define (parse tokens)
  (define-values (value rest) (parse-expr tokens))
  (unless (null? rest)
    (calc-error "calculate: unexpected trailing input at ~s"
                (string-join (map token-text rest) " ")))
  value)

(define (parse-expr tokens)
  (define-values (left rest) (parse-term tokens))
  (let loop ([left left] [rest rest])
    (cond
      [(and (pair? rest) (memq (token-kind (car rest)) (list #\+ #\-)))
       (define-values (right more) (parse-term (cdr rest)))
       (loop ((if (eq? (token-kind (car rest)) #\+) + -) left right) more)]
      [else (values left rest)])))

(define (parse-term tokens)
  (define-values (left rest) (parse-unary tokens))
  (let loop ([left left] [rest rest])
    (cond
      [(and (pair? rest)
            (memq (token-kind (car rest)) (list #\* #\/ #\% 'mul 'div)))
       (define op (token-kind (car rest)))
       (define-values (right more) (parse-unary (cdr rest)))
       (loop (case op
               [(#\* mul) (* left right)]
               [(#\/ div) (safe-division left right)]
               [else (safe-modulo left right)])
             more)]
      [else (values left rest)])))

(define (parse-unary tokens)
  (cond
    [(and (pair? tokens) (eq? (token-kind (car tokens)) #\-))
     (define-values (value rest) (parse-unary (cdr tokens)))
     (values (- value) rest)]
    [else (parse-power tokens)]))

(define (parse-power tokens)
  (define-values (base rest) (parse-atom tokens))
  (define-values (value rest*) (parse-postfix base rest))
  (cond
    [(and (pair? rest*) (eq? (token-kind (car rest*)) #\^))
     ;; Right-associative: 2^3^2 = 2^(3^2).
     (define-values (exponent more) (parse-unary (cdr rest*)))
     (values (expt value exponent) more)]
    [else (values value rest*)]))

(define (parse-postfix value tokens)
  (if (and (pair? tokens) (eq? (token-kind (car tokens)) #\!))
      (parse-postfix (factorial (inexact->exact (floor value))) (cdr tokens))
      (values value tokens)))

(define (parse-atom tokens)
  (match tokens
    [(list (token 'number text) rest ...)
     (values (parse-number text) rest)]
    [(list (token #\( _) rest ...)
     (define-values (value after) (parse-expr rest))
     (match after
       [(list (token #\) _) more ...) (values value more)]
       [else (calc-error "calculate: expected closing parenthesis")])]
    [(list (token 'ident name) (token #\( _) rest ...)
     (parse-call (string->symbol name) rest)]
    [(list (token 'ident name) rest ...)
     (define sym (string->symbol name))
     (cond
       [(hash-ref constants sym #f) => (lambda (v) (values v rest))]
       [(hash-has-key? functions sym)
        (calc-error "calculate: ~a expects arguments, e.g. ~a(2)" name name)]
       [else (calc-error "calculate: unknown name ~s" name)])]
    [else (calc-error "calculate: unexpected end of expression")]))

(define (parse-call name tokens)
  (define spec
    (hash-ref functions name
              (lambda () (calc-error "calculate: unknown function ~s" name))))
  (define arity (car spec))
  (define fn (cdr spec))
  ;; Math-domain failures (log(0), asin(2), …) surface as plain exn:fail.
  ;; Convert them so every calculate failure is an exn:calc with one line.
  (define (call-fn args)
    (with-handlers ([exn:calc? (lambda (e) (raise e))]
                    [exn:fail?
                     (lambda (e)
                       (calc-error "calculate: ~a"
                                   (string-replace (exn-message e) "\n" " ")))])
      (apply fn args)))
  (let loop ([rest tokens] [args '()])
    (cond
      [(= (length args) arity)
       (match rest
         [(list (token #\) _) more ...) (values (call-fn (reverse args)) more)]
         [else (calc-error "calculate: ~a expects ~a argument~a"
                           name arity (if (= arity 1) "" "s"))])]
      [else
       (define-values (value after) (parse-expr rest))
       (match after
         [(list (token #\, _) more ...) (loop more (cons value args))]
         [(list (token #\) _) more ...)
          (loop (cons (token #\) ")") more) (cons value args))]
         [else (calc-error "calculate: expected , or ) in call to ~a" name)])])))

;; ---- Arithmetic guards --------------------------------------------------

(define (require-real who value)
  (unless (real? value)
    (calc-error "calculate: ~a needs a real number" who))
  value)

(define (safe-division a b)
  (require-real "division" a)
  (require-real "division" b)
  (when (zero? b) (calc-error "calculate: division by zero"))
  (/ a b))

(define (safe-modulo a b)
  (require-real "modulo" a)
  (require-real "modulo" b)
  (when (zero? b) (calc-error "calculate: division by zero"))
  (modulo (inexact->exact (floor a)) (inexact->exact (floor b))))

(define (parse-number text)
  (or (string->number text 10 'read)
      (calc-error "calculate: invalid number ~s" text)))

;; ---- Public API ---------------------------------------------------------

(define/contract (calculate expression)
  (-> string? real?)
  (unless (string? expression)
    (raise-argument-error 'calculate "string?" expression))
  (define value (parse (tokenize expression)))
  (unless (real? value)
    (calc-error "calculate: result is not a real number"))
  value)

(define (display-number value)
  (cond
    [(and (exact? value) (integer? value)) (number->string value)]
    [(equal? value (floor value)) (number->string (exact-floor value))]
    [else
     (define text (~r (exact->inexact value) #:precision '(= 10)))
     (define trimmed (regexp-replace* #rx"0+$" text ""))
     (regexp-replace* #rx"\\.$" trimmed "")]))

(define/contract (calculate-display expression)
  (-> string? string?)
  (display-number (calculate expression)))
