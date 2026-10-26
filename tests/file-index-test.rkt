#lang racket/base

(require racket/file
         rackunit
         "../app/core/file-index.rkt")

(define (with-index thunk)
  (define dir (make-temporary-file "fulcrum-file-index-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (thunk (build-path dir "index.sqlite3")))
    (lambda () (delete-directory/files dir))))

(test-case "persistent index orders exact stem before prefix across path styles"
  (with-index
   (lambda (path)
     (check-true
      (file-index-upsert-hits!
       path
       '(('dummy . "ignored"))))
     ;; Invalid rows are ignored; real entries cover Windows, POSIX, Unicode,
     ;; and case-folded lookup without depending on the test host's path rules.
     (check-true
      (file-index-upsert-hits!
       path
       '(("Report-old.txt" . "C:\\Users\\me\\Report-old.txt")
         ("report.md" . "/home/me/report.md")
         ("REPORTING.xlsx" . "/home/me/REPORTING.xlsx")
         ("报告.md" . "D:\\资料\\报告.md"))))
     (check-equal? (file-index-count path) 4)
     (check-equal?
      (file-index-search path "report" 4)
      '(("report.md" . "/home/me/report.md")
        ("Report-old.txt" . "C:\\Users\\me\\Report-old.txt")
        ("REPORTING.xlsx" . "/home/me/REPORTING.xlsx")))
     (check-equal? (file-index-search path "报告" 8)
                   '(("报告.md" . "D:\\资料\\报告.md"))))))

(test-case "incremental add rename and remove survive reopen"
  (with-index
   (lambda (path)
     (file-index-upsert-hits!
      path
      '(("alpha.txt" . "/docs/alpha.txt")
        ("beta.txt" . "/docs/beta.txt")))
     (check-true
      (file-index-rename! path "/docs/alpha.txt" "C:\\Docs\\alpha-final.txt"))
     (check-equal? (file-index-search path "alpha" 8)
                   '(("alpha-final.txt" . "C:\\Docs\\alpha-final.txt")))
     (check-true (file-index-remove-paths! path '("/docs/beta.txt")))
     ;; Every API call opens a fresh connection, exercising persistent rather
     ;; than process-local state.
     (check-equal? (file-index-count path) 1)
     (check-equal? (file-index-search path "beta" 8) '()))))

(test-case "corrupt cache is discarded and rebuilt safely"
  (with-index
   (lambda (path)
     (call-with-output-file path
       (lambda (out) (display "not a sqlite database" out))
       #:exists 'truncate)
     (check-equal? (file-index-count path) 0)
     (check-true
      (file-index-upsert-hits! path '(("recovered.md" . "/docs/recovered.md"))))
     (check-equal? (file-index-search path "recover" 8)
                   '(("recovered.md" . "/docs/recovered.md"))))))
