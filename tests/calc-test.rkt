#lang racket/base

;; Calculator contract tests: arithmetic, precedence, functions, constants,
;; error surface. Everything that goes wrong must be an exn:calc with a
;; one-line message — the launcher renders it inline.

(require racket/string
         rackunit
         "../app/core/calc.rkt")

(define (calc-error-message expression)
  (with-handlers ([exn:calc? exn-message]
                  [exn:fail? (lambda (e) (format "WRONG-ERROR-TYPE: ~a" (exn-message e)))])
    (calculate-display expression)
    "NO-ERROR"))

(test-case "arithmetic"
  (check-equal? (calculate-display "1+2*3") "7")
  (check-equal? (calculate-display "(1+2)*3") "9")
  (check-equal? (calculate-display "10/4") "2.5")
  (check-equal? (calculate-display "2^3^2") "512" "right-associative")
  (check-equal? (calculate-display "-3^2") "-9" "unary minus binds looser than ^")
  (check-equal? (calculate-display "10%3") "1")
  (check-equal? (calculate-display "2*3.5") "7")
  (check-equal? (calculate-display "1e2+1") "101" "scientific notation"))

(test-case "functions and constants"
  (check-equal? (calculate-display "sqrt(16)") "4")
  (check-equal? (calculate-display "max(3,7)*2") "14")
  (check-equal? (calculate-display "5!") "120")
  (check-equal? (calculate-display "fact(5)") "120")
  (check-equal? (calculate-display "abs(3-9)") "6")
  (check-equal? (calculate-display "log(100)") "2")
  (check-equal? (calculate-display "ln(e)") "1")
  (check-equal? (calculate-display "floor(2.7)") "2")
  (check-equal? (calculate-display "round(2.6)") "3")
  (check-true (string-prefix? (calculate-display "pi") "3.14159")))

(test-case "errors are exn:calc with one-line messages"
  (check-equal? (calc-error-message "1/0") "calculate: division by zero")
  (check-equal? (calc-error-message "2+(3") "calculate: expected closing parenthesis")
  (check-equal? (calc-error-message "foo(2)") "calculate: unknown function foo")
  (check-true (string-prefix? (calc-error-message "log(0)") "calculate:")
              "domain errors convert to exn:calc")
  (check-true (string-prefix? (calc-error-message "5+5 3") "calculate:")
              "trailing input rejected")
  (check-true (string-contains? (calc-error-message "(170+1)!") "out of range")
              "factorial overflow is bounded"))

(test-case "hostile input cannot execute"
  (check-true (string-prefix? (calc-error-message "(read") "calculate:")
              "s-expression input is not evaluated")
  (check-true (string-prefix? (calc-error-message "(+ 1 2)") "calculate:")
              "lisp application syntax is rejected"))

(test-case "calculate-functions is sorted and complete"
  (define names (calculate-functions))
  (check-true (and (member "sqrt" names) #t))
  (check-true (and (member "min" names) #t))
  (check-equal? names (sort names string<?)))
