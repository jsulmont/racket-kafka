#lang racket/base

(require (for-syntax racket/base
                     racket/list
                     racket/syntax
                     syntax/parse)
         racket/contract
         "../connection.rkt"
         "../error.rkt"
         "../help.rkt"
         (prefix-in proto: "../protocol.bnf")
         "contract.rkt")

(provide
 (all-from-out
  "../connection.rkt"
  "../help.rkt"
  "../protocol.bnf"
  "contract.rkt")
 define-record
 define-request)

(begin-for-syntax
  (define (id-stx->keyword stx)
    (datum->syntax stx (string->keyword (symbol->string (syntax-e stx)))))

  (define-syntax-class record-fld
    (pattern [id:id ctc:expr]
             #:with required? #'#t
             #:with kwd (id-stx->keyword #'id)
             #:with arg #'id)
    (pattern [(id:id def:expr) ctc:expr]
             #:with required? #'#f
             #:with kwd (id-stx->keyword #'id)
             #:with arg #'[id def])))

(define-syntax (define-record stx)
  (syntax-parse stx
    [(_ id:id (fld:record-fld ...))
     #:with id? (format-id #'id "~a?" #'id)
     #:with constructor-id (format-id #'id "make-~a" #'id)
     #:with (constructor-arg ...) (flatten
                                   (for/list ([kwd (in-list (syntax-e #'(fld.kwd ...)))]
                                              [arg (in-list (syntax-e #'(fld.arg ...)))])
                                     (list kwd arg)))
     #:with (required-ctor-arg-ctc ...) (flatten
                                         (for/list ([req? (in-list (syntax->datum #'(fld.required? ...)))]
                                                    [kwd  (in-list (syntax-e #'(fld.kwd ...)))]
                                                    [ctc  (in-list (syntax-e #'(fld.ctc ...)))]
                                                    #:when req?)
                                           (list kwd ctc)))
     #:with (optional-ctor-arg-ctc ...) (flatten
                                         (for/list ([req? (in-list (syntax->datum #'(fld.required? ...)))]
                                                    [kwd  (in-list (syntax-e #'(fld.kwd ...)))]
                                                    [ctc  (in-list (syntax-e #'(fld.ctc ...)))]
                                                    #:unless req?)
                                           (list kwd ctc)))
     #'(begin
         (provide
          (contract-out
           [struct id ([fld.id fld.ctc] ...)]
           [constructor-id (->* (required-ctor-arg-ctc ...)
                                (optional-ctor-arg-ctc ...)
                                id?)]))
         (struct id (fld.id ...) #:transparent)
         (define (constructor-id constructor-arg ...)
           (id fld.id ...)))]))

(begin-for-syntax
  (define-syntax-class request-arg
    (pattern id:id)
    (pattern [id:id def:expr])))

(define-syntax (define-request stx)
  (syntax-parse stx
    [(_ id:id
        (arg:request-arg ...)
        {~seq #:code key:number}
        {~seq #:version version-num:number
              {~optional {~seq #:flexible flexible}}
              #:response parser:expr
              encoder:expr
              decoder:expr} ...+)
     #:with make-evt-id (format-id #'id "make-~a-evt" #'id)
     #:with version-rng-id (format-id #'id "~a-supported-versions" #'id)
     #:with version-rng (let ([versions (map syntax->datum (syntax-e #'(version-num ...)))])
                          (with-syntax ([min-v (apply min versions)]
                                        [max-v (apply max versions)])
                            #'(version-range min-v max-v)))
     #'(begin
         (provide make-evt-id)
         (define version-rng-id version-rng)
         (define (make-evt conn flexible? v data parser-proc proc)
           (handle-evt
            (make-request-evt
             conn
             #:key key
             #:version v
             #:data data
             #:parser parser-proc
             #:flexible? flexible?)
            (lambda (res)
              (define err-code (or (opt 'ErrorCode_1 res) 0))
              (unless (zero? err-code)
                (raise-server-error err-code))
              (proc res))))
         (define (make-evt-id conn arg ...)
           (case (find-best-version conn key version-rng-id)
             [(version-num) (make-evt conn {~? flexible #f} version-num (encoder arg.id ...) parser decoder)] ...
             [else (error 'make-evt-id "no supported version")])))]))