#lang racket/base

;; JSON persistence with atomic replacement.
;;
;; All Fulcrum stores follow the same durability rule: write to a temporary
;; file in the same directory, fsync-free atomic rename, never leave a partial
;; JSON document. Readers treat any read failure as "use the default" because
;; every store can be rebuilt or survives losing its cache.

(require json
         racket/file
         racket/os
         racket/path)

(provide read-json-file
         write-json-atomic!
         update-json-atomic!)

(define io-lock (make-semaphore 1))

(define (read-json-file path default)
  (call-with-semaphore
   io-lock
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_) default)])
       (call-with-input-file path
         (lambda (in)
           (define value (read-json in))
           (if (eof-object? value) default value)))))))

(define (write-json-atomic! path value)
  (define parent (path-only path))
  (when parent (make-directory* parent))
  (define tmp (make-temporary-file "fulcrum-~a.json" #f (or parent (current-directory))))
  (call-with-semaphore
   io-lock
   (lambda ()
     (dynamic-wind
       (lambda () (void))
       (lambda ()
         (with-output-to-file tmp
           (lambda () (write-json value))
           #:exists 'replace)
         (rename-file-or-directory tmp path #t))
       (lambda ()
         (with-handlers ([exn:fail? (lambda (_) (void))])
           (when (file-exists? tmp) (delete-file tmp))))))))

(define (update-json-atomic! path default update)
  (define next (update (read-json-file path default)))
  (write-json-atomic! path next)
  next)
