#lang racket/base

(require box-extra
         racket/random
         sasl
         "connection.rkt"
         "serde.rkt")

(provide
 client?
 make-client
 get-connection
 disconnect-all)

(struct client
  (sasl-mechanism&ctx
   ssl-ctx
   brokers
   connections-box
   update-connections-box))

(define (make-client
         #:bootstrap-host [host "127.0.0.1"]
         #:bootstrap-port [port 9092]
         #:sasl-mechanism&ctx [sasl-mechanism&ctx #f]
         #:ssl-ctx [ssl-ctx #f])
  (define bootstrap-conn
    (connect host port ssl-ctx))
  (when sasl-mechanism&ctx
    (apply authenticate bootstrap-conn sasl-mechanism&ctx))
  (define brokers
    (Metadata-brokers
     (sync (make-Metadata-evt bootstrap-conn null))))
  (disconnect bootstrap-conn)
  (when (null? brokers)
    (error 'make-client "failed to discover any brokers"))
  (define connections-box
    (box (hasheqv)))
  (define update-connections-box
    (make-box-update-proc connections-box))
  (client sasl-mechanism&ctx ssl-ctx brokers connections-box update-connections-box))

(define (get-connection c)
  (define conns (drop-disconnected c))
  (define brokers (client-brokers c))
  (define connected-node-ids (hash-keys conns))
  (define unconnected-brokers
    (for*/list ([b (in-list brokers)]
                [node-id (in-value (BrokerMetadata-node-id b))]
                #:unless (memv node-id connected-node-ids))
      b))
  (if (null? unconnected-brokers)
      (find-best-connection conns)
      (establish-new-connection c conns unconnected-brokers)))

(define (disconnect-all c)
  (define connections-box (client-connections-box c))
  (for/list ([conn (in-hash-values (unbox connections-box))])
    (disconnect conn))
  (set-box! connections-box (hasheqv)))

(define (drop-disconnected c)
  ((client-update-connections-box c)
   (λ (conns)
     (for/hasheqv ([(node-id conn) (in-hash conns)] #:when (connected? conn))
       (values node-id conn)))))

(define (establish-new-connection c conns brokers)
  (define broker (random-ref brokers))
  (define node-id (BrokerMetadata-node-id broker))
  (define conn
    (connect
     (BrokerMetadata-host broker)
     (BrokerMetadata-port broker)
     (client-ssl-ctx c)))
  (when (client-sasl-mechanism&ctx c)
    (apply authenticate conn (client-sasl-mechanism&ctx c)))
  (define connections-box
    (client-connections-box c))
  (define updated-conns
    (hash-set conns node-id conn))
  (let loop ()
    (cond
      [(box-cas! connections-box conns updated-conns)
       (begin0 conn
         (log-kafka-debug "established connection to node ~a" node-id))]
      [(equal? (unbox connections-box) conns)
       (log-kafka-debug "spurious error during cas, retrying")
       (loop)]
      [else
       (log-kafka-debug "lost race while establishing connection, disconnecting")
       (disconnect conn)
       (log-kafka-debug "retrying get-connection")
       (get-connection c)])))

(define (find-best-connection conns)
  (for/fold ([best #f]
             [least-reqs +inf.0]
             #:result best)
            ([conn (in-hash-values conns)])
    (define reqs (get-requests-in-flight conn))
    #:final (zero? reqs)
    (if (< reqs least-reqs)
        (values conn reqs)
        (values best least-reqs))))

(define (authenticate conn mechanism ctx)
  (sync (make-SaslHandshake-evt conn mechanism))
  (case mechanism
    [(plain)
     (define req
       (if (string? ctx)
           (string->bytes/utf-8 ctx)
           ctx))
     (sync (make-SaslAuthenticate-evt conn req))]
    [else
     (let loop ()
       (case (sasl-state ctx)
         [(done)
          (void)]
         [(error)
          (error 'authenticate "SASL: unexpected error")]
         [(receive)
          (error 'authenticate "SASL: receive not supported")]
         [(send/receive)
          (define req (sasl-next-message ctx))
          (define res (sync (make-SaslAuthenticate-evt conn req)))
          (sasl-receive-message ctx (SaslAuthenticateResponse-data res))
          (loop)]
         [(send/done)
          (define req (sasl-next-message ctx))
          (sync (make-SaslAuthenticate-evt conn req))]))])
  (void))