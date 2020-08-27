;;; -*- mode:scheme; coding:utf-8; -*-
;;;
;;; postgresql/apis.sld - PostgreSQL API
;;;
;;;   Copyright (c) 2014-2015  Takashi Kato  <ktakashi@ymail.com>
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;

(define-library (cyclone postgresql apis)
  (export make-postgresql-connection
	  postgresql-connection?
	  postgresql-open-connection!
	  postgresql-secure-connection!
	  postgresql-login!
	  postgresql-terminate!

	  ;; simple query
	  postgresql-query?
	  postgresql-query-descriptions
	  postgresql-execute-sql!

	  ;; prepared statement
	  postgresql-prepared-statement?
	  postgresql-prepared-statement
	  postgresql-prepared-statement-sql ;; for observation
	  postgresql-bind-parameters!
	  postgresql-execute!
	  postgresql-close-prepared-statement!

	  ;; configuration parameter
	  *postgresql-maximum-results*
	  *postgresql-date-format*
	  *postgresql-time-format*
	  *postgresql-timestamp-format*
	  *postgresql-copy-data-handler*
	  *postgresql-write-data-handler*
	  *postgresql-notice-handler*
	  *postgresql-unknown-type-handler*

	  postgresql-fetch-query!

	  ;; some of utilities
	  postgresql-start-transaction!
	  postgresql-commit!
	  postgresql-rollback!

	  ;; transaction mode
	  postgresql-transaction-mode
	  ;; variables
	  postgresql-isolation-level-serializable
	  postgresql-isolation-level-repeatable-read
	  postgresql-isolation-level-read-committed
	  postgresql-isolation-level-read-uncommitted
	  postgresql-access-mode-read-write
	  postgresql-access-mode-read-only
	  postgresql-deferrable-on
	  postgresql-deferrable-off)
  (import (scheme base)
	  (scheme write)
	  (scheme char)
	  (srfi 106)
          (cyclone bytevector)
          (cyclone crypto md5)
	  (cyclone postgresql misc ssl)
          (cyclone postgresql buffer))
  (begin
    ;; default 50
    (define (->date str templ zone?) str)
    (define (->timestamp str templ zone?) str)
    (define *postgresql-maximum-results* (make-parameter 50))
    (define *postgresql-date-format* (make-parameter "~Y-~m-~d"))
    (define *postgresql-time-format* (make-parameter "~H:~M:~S"))
    (define *postgresql-timestamp-format* (make-parameter "~Y-~m-~d~H:~M:~S"))
    ;; default doing nothing
    (define (default-copy-data-handler type data) #f)
    (define (default-notice-handler code payload) #f)
    (define (default-unknown-type-handler type value) value)

    (define *postgresql-copy-data-handler*
      (make-parameter default-copy-data-handler))
    (define *postgresql-write-data-handler*
      (make-parameter default-copy-data-handler))
    (define *postgresql-notice-handler*
      (make-parameter default-notice-handler))
    (define *postgresql-unknown-type-handler*
      (make-parameter default-unknown-type-handler))

    (define (make-postgresql-connection host port database username password)
      (%make-postgresql-connection host port database username password
       #f
       #f
       #f
       #f
       #f
       #f
       #f))

    (define-record-type postgresql-connection
      (%make-postgresql-connection host port database username password
       socket   
       sock-in  
       sock-out 
       params   
       id       
       key      
       counter) 

      postgresql-connection?
      (host     postgresql-connection-host)
      (port     postgresql-connection-port)
      (database postgresql-connection-database)
      (username postgresql-connection-username)
      (password postgresql-connection-password)
      ;; after it's opened
      (socket   postgresql-connection-socket postgresql-connection-socket-set!)
      ;; input and output ports
      (sock-in  postgresql-connection-sock-in
                postgresql-connection-sock-in-set!)
      (sock-out postgresql-connection-sock-out
                postgresql-connection-sock-out-set!)
      (params   postgresql-connection-params postgresql-connection-params-set!)
      (id       postgresql-connection-id postgresql-connection-id-set!)
      (key      postgresql-connection-key postgresql-connection-key-set!)
      (counter  postgresql-connection-counter
                postgresql-connection-counter-set!))

    ;; gensym would be easier but not portable...
    (define (generate-unique-string conn)
      (let ((counter (postgresql-connection-counter conn)))
        (postgresql-connection-counter-set! conn (+ counter 1))
        (string-append (postgresql-connection-username conn)
                       (number->string (postgresql-connection-id conn))
                       (number->string counter))))

    (define (postgresql-open-connection! conn)
      (when (socket? (postgresql-connection-socket conn))
        ;; TODO should we try to send terminate?
        (close-conn conn))
      (let ((s (make-client-socket (postgresql-connection-host conn)
                                   (postgresql-connection-port conn))))
        (postgresql-connection-socket-set! conn s)
        (postgresql-connection-sock-in-set! conn (socket-input-port s))
        (postgresql-connection-sock-out-set! conn
                                             (make-postgresql-out-buffer (socket-output-port s)))
        (postgresql-connection-counter-set! conn 0)
        conn))

    (define (close-conn conn)
      (define sock (postgresql-connection-socket conn))
      (if (ssl-socket? sock)
          (ssl-socket-close sock)
          (socket-close sock))
      ;; invalidate it
      (postgresql-connection-socket-set! conn #f))

    ;; can be used anywhere
    (define (read-null-terminated-string params i)
      (let ((out (open-output-string)))
        (let loop ((i i))
          (let ((b (bytevector-u8-ref params i)))
            (if (zero? b)
                (values (+ i 1) (get-output-string out))
                (begin
                  (write-char (integer->char b) out)
                  (loop (+ i 1))))))))

    (define (postgresql-secure-connection! conn)
      (define in  (postgresql-connection-sock-in conn))
      (define out (postgresql-connection-sock-out conn))
      (define (do-negotiation)
        (postgresql-send-ssl-request out)
        (case (integer->char (read-u8 in))
          ((#\S)
           (let ((sock (socket->ssl-socket
                        (postgresql-connection-socket conn))))
             (postgresql-connection-socket-set! conn sock)
             (postgresql-connection-sock-in-set! conn
                                                 (ssl-socket-input-port sock))
             (postgresql-connection-sock-out-set! conn
                                                  (make-postgresql-out-buffer (ssl-socket-output-port sock)))
             #t))
          ((#\N) #f)
          (else (error "postgresql-secure-connection!: unknown response"))))
      (or (ssl-socket? (postgresql-connection-socket conn))
          (do-negotiation)))
    
    (define (postgresql-login! conn . maybe-ssl)
      (define ssl? (and (not (null? maybe-ssl)) (car maybe-ssl)))
      (define read-string read-null-terminated-string)
      (define (store-params params)
        (define len (bytevector-length params))
        ;; convert it to alist ((name . value))
        ;; name is symbol, value is string
        (let loop ((i 0) (r '()))
          (let*-values (((next name) (read-string params i))
                        ((next value) (read-string params next)))
            (if (= len next)
                (postgresql-connection-params-set! conn r)
                (loop next (cons (cons (string->symbol name) value) r))))))
      (define (next in)
        (let-values (((code payload) (postgresql-read-response in)))
          (case code
            ((#\K)
             (let ((id (bytevector-u32-ref-be payload 0))
                   (key (bytevector-u32-ref-be payload 4)))
               (postgresql-connection-id-set! conn id)
               (postgresql-connection-key-set! conn key)
               (next in)))
            ((#\S)
             (store-params payload)
             (next in))
            ((#\N)
             (let ((code (integer->char (bytevector-u8-ref payload 0))))
               ((*postgresql-notice-handler*) code (utf8->string payload 1))
               (next in)))
            ((#\Z) #t))))
      (when (and ssl? (not (postgresql-secure-connection! conn)))
        (close-conn conn)
        (error "Failed to establish SSL connection"))
      (let ((in   (postgresql-connection-sock-in conn))
            (out  (postgresql-connection-sock-out conn))
            (user (postgresql-connection-username conn))
            (pass (postgresql-connection-password conn))
            (database (let ((d (postgresql-connection-database conn)))
                        (if d (list (cons "database" d)) '()))))
        (postgresql-send-startup-message out (cons (cons "user" user) database))
        ;; authenticate
        (let loop ((first #t))
          ;; concat('md5', md5(concat(md5(concat(password, username)),
          ;;                          random-salt)))
          ;; PostgreSQL md5 function returns hex string in small letters,
          ;; so we need to do some trick here.
          ;; it horribly sucks but it's inevitable...
          (define (construct payload)
            (let* ((pu5 (md5 (string-append pass user)))
                   (pus5 (md5 (bytevector-append (string->utf8 pu5)
                                                 (bytevector-copy payload 4)))))
              (string-append "md5" pus5)))
          (define (send-password conn payload)
            (unless first
              (error "postgresql-login!: failed to login"))
            (if (= (bytevector-length payload) 4)
                (postgresql-send-password-message out pass)
                (postgresql-send-password-message out (construct payload))))
          (let-values (((code payload) (postgresql-read-response in)))
            (unless (char=? code #\R)
              (close-conn conn)
              (error "postgresql-login!: server respond unexpected message"
                     code))
            ;; get content
            (case (bytevector-u32-ref-be payload 0)
              ((0) (next in)) ;; ok
              ((3) (send-password conn payload) (loop #f))
              ((5) (send-password conn payload) (loop #f))
              (else
               (close-conn conn)
               (error "postgresql-login!: unsupported login method")))))))

    (define (postgresql-terminate! conn)
      (let ((out (postgresql-connection-sock-out conn)))
        (postgresql-send-terminate-message out)
        (close-conn conn)))

    (define-record-type transaction-mode
      (make-posgresql-transaction-mode isolation access-mode deferrable)
      postgresql-transaction-mode?
      (isolation   postgresql-transaction-mode-isolation-level
                   postgresql-transaction-mode-isolation-level-set!)
      (access-mode postgresql-transaction-mode-access-mode
                   postgresql-transaction-mode-access-mode-set!)
      (deferrable  postgresql-transaction-mode-deferrable
        postgresql-transaction-mode-deferrable-set!))

    ;; isolation level
    (define postgresql-isolation-level-serializable     "SERIALIZABLE")
    (define postgresql-isolation-level-repeatable-read  "REPEATABLE READ")
    (define postgresql-isolation-level-read-committed   "READ COMMITTED")
    (define postgresql-isolation-level-read-uncommitted "READ UNCOMMITTED")
    ;; followings have space before the command
    ;; access-mode
    (define postgresql-access-mode-read-write " READ WRITE")
    (define postgresql-access-mode-read-only  " READ ONLY")
    ;; deferrable
    (define postgresql-deferrable-on  " DEFERRABLE")
    (define postgresql-deferrable-off " NOT DEFERRABLE")


    (define (postgresql-transaction-mode alist)
      (define (alist-ref name alist)
        (cond ((assq name alist) => cdr)
              (else #f)))
      (let ((level  (alist-ref 'isolation-level alist))
            (access (alist-ref 'access-mode    alist))
            (deferrable? (alist-ref 'deferrable? alist)))
        (make-posgresql-transaction-mode level access deferrable?)))

    ;; these are mere SQL
    (define (postgresql-start-transaction! conn mode)
      (define (construct-mode mode)
        (let ((isolation (postgresql-transaction-mode-isolation-level mode))
              (access    (postgresql-transaction-mode-access-mode mode))
              (deferable (postgresql-transaction-mode-deferrable mode)))
          ;; thank to the backward compatibility of PostgreSQL
          ;; we don't need ',' :)
          (string-append (if isolation
                             (string-append " ISOLATION LEVEL " isolation)
                             "")
                         (if access access "")
                         (if deferable deferable ""))))
      (if mode
          (let ((modes (construct-mode mode)))
            (postgresql-execute-sql! conn (string-append "START TRANSACTION"
                                                         modes)))
          (postgresql-execute-sql! conn "START TRANSACTION")))
    (define (postgresql-commit! conn)
      (postgresql-execute-sql! conn "COMMIT"))
    (define (postgresql-rollback! conn)
      (postgresql-execute-sql! conn "ROLLBACK"))

    (define (make-postgresql-query connection buffer cursor statement eoq)
      (%make-postgresql-query connection #f buffer cursor statement eoq))

    (define-record-type postgresql-query
      (%make-postgresql-query connection descriptions buffer cursor statement eoq)
      postgresql-query?
      (connection   postgresql-query-connection)
      (descriptions postgresql-query-descriptions
                    postgresql-query-descriptions-set!)
      (buffer       postgresql-query-buffer postgresql-query-buffer-set!)
      (cursor       postgresql-query-cursor postgresql-query-cursor-set!)
      (statement    postgresql-query-statement)
      ;; end of query
      (eoq          postgresql-query-eoq postgresql-query-eoq-set!))

    ;; parse description to a vector
    ;; a description:
    ;;  #(name table-id column-num type-id type-size type-modifier format-code)
    (define (parse-row-description payload k)
      (define read-string read-null-terminated-string)
      (let* ((n (bytevector-u16-ref-be payload 0))
             (vec (make-vector n #f)))
        (let loop ((offset 2) (i 0))
          (if (= i n)
              (k vec)
              (let-values (((next name) (read-string payload offset)))
                (let ((table-id   (bytevector-u32-ref-be payload next))
                      (column-num (bytevector-u16-ref-be payload (+ next 4)))
                      (type-id    (bytevector-u32-ref-be payload (+ next 6)))
                      (type-size  (bytevector-u16-ref-be payload (+ next 10)))
                      (type-mod   (bytevector-u32-ref-be payload (+ next 12)))
                      (fmt-code   (bytevector-u16-ref-be payload (+ next 16))))
                  (vector-set! vec i (vector name table-id column-num type-id
                                             type-size type-mod fmt-code))
                  (loop (+ next 18) (+ i 1))))))))

    (define (->u16-list bv offset)
      (let ((len (bytevector-length bv)))
        (let loop ((i offset) (r '()))
          (if (= i len)
              (reverse r)
              (loop (+ i 2) (cons (bytevector-u16-ref-be bv offset) r))))))

    (define (->copy-data-header payload)
      (list (bytevector-u8-ref payload 0)
            (bytevector-u16-ref-be payload 1)
            (->u16-list payload 3)))

    ;; handling writing data.
    ;; FIXME this works fine but ugly...
    (define (call-data-writer payload in out need-sync?)
      (with-exception-handler
          ;; handling user error
          ;; handler can raise an error to reject the process.
          ;; in that case we need to consider 2 things, one is
          ;; simple query which automatically sends ReadyForQuery
          ;; other one is advanced process. The latter one, we
          ;; need to send Sync message explicitly.
          (lambda (e)
            (postgresql-send-copy-fail-message out (error-object-message e))
            (with-exception-handler
                (lambda (e2)
                  (when need-sync?
                    (postgresql-send-sync-message out)
                    (postgresql-read-response in))
                  (raise e2))
              (lambda () (postgresql-read-response in))))
        (lambda ()
          ((*postgresql-write-data-handler*) 'header
           (->copy-data-header payload))
          (let ((h (*postgresql-write-data-handler*)))
            (do ((r (h 'data #f) (h 'data #f)))
                ((not r))
              (postgresql-send-copy-data-message out r))
            (h 'complete #t))
          (postgresql-send-copy-done-message out)
          (postgresql-send-flush-message out)))
      ;; it's a bit ugly
      (with-exception-handler
          (lambda (e)
            (when need-sync?
              (postgresql-send-sync-message out)
              ;; ignore #\Z
              (postgresql-read-response in))
            (raise e))
        (lambda ()
          (postgresql-read-response in) ;; #\c or error
          (when need-sync? (postgresql-send-sync-message out))
          (postgresql-read-response in) ;; must be #\Z
          )))

    ;; this is very inefficient one, do not use for
    ;; big query like more than 10000 or so
    (define (postgresql-execute-sql! conn sql)
      (let ((out (postgresql-connection-sock-out conn))
            (in  (postgresql-connection-sock-in conn)))
        (postgresql-send-sync-message out)
        (postgresql-read-response in) ;; ignore #\Z

        (postgresql-send-query-message out sql)
        (postgresql-send-flush-message out)
        ;; get
        (guard (e (else
                   ;; must be #\E so we need to receive #\Z
                   (postgresql-read-response in)
                   (raise e)))
          (let loop ((r #t) (rows '()))
            (let-values (((code payload) (postgresql-read-response in)))
              (case code
                ((#\C)           ;; CommandComplete
                 (cond ((postgresql-query? r)
                        (postgresql-query-eoq-set! r #t)
                        (loop r rows))
                       (else
                        ;; create query
                        (loop (parse-command-complete payload) rows))))
                ((#\Z)           ;; ReadyForQuery
                 (when (postgresql-query? r)
                   (postgresql-query-buffer-set! r
                                                 (list->vector (reverse rows)))
                   (postgresql-query-cursor-set! r 0))
                 r)
                ((#\T)	       ;; RowDescription
                 ;; TODO should we store records?
                 (let ((query (make-postgresql-query conn #f #f #f #f)))
                   (loop (parse-row-description payload
                                                (lambda (vec)
                                                  (postgresql-query-descriptions-set! query vec)
                                                  query)) rows)))
                ((#\D)
                 (let ((rows (if (postgresql-query? r)
                                 (cons (parse-record r payload) rows)
                                 rows)))
                   (loop r rows)))
                ((#\G)
                 (call-data-writer payload in out #f)
                 r)
                ;; just return as it is
                ((#\H)
                 ((*postgresql-copy-data-handler*) 'header
                  (->copy-data-header payload))
                 (loop r rows))
                ((#\d)
                 ((*postgresql-copy-data-handler*) 'data payload)
                 (loop r rows))
                ((#\c)
                 ((*postgresql-copy-data-handler*) 'complete #f)
                 (loop r rows))
                ((#\N)
                 (let ((code (integer->char (bytevector-u8-ref payload 0))))
                   ((*postgresql-notice-handler*) code (utf8->string payload 1))
                   (loop r rows)))
                ;; else? ignore
                (else (loop r rows))))))))

    (define (make-postgresql-prepared-statement connection sql parameters portal)
      (%make-postgresql-prepared-statement connection sql #f portal parameters #f #f))

    (define-record-type postgresql-statement
      (%make-postgresql-prepared-statement connection sql name portal parameters oids descriptions)
      postgresql-prepared-statement?
      (connection postgresql-prepared-statement-connection)
      (sql        postgresql-prepared-statement-sql)
      ;; prepared statement name
      (name       postgresql-prepared-statement-name
                  postgresql-prepared-statement-name-set!)
      ;; underling portal name
      (portal     postgresql-prepared-statement-portal
                  postgresql-prepared-statement-portal-set!)
      (parameters postgresql-prepared-statement-parameters
                  postgresql-prepared-statement-parameters-set!)
      ;; object id of the parameter data type
      (oids       postgresql-prepared-statement-oids
                  postgresql-prepared-statement-oids-set!)
      ;; column descriptions
      (descriptions postgresql-prepared-statement-descriptions
                    postgresql-prepared-statement-descriptions-set!))

    (define (init-prepared-statement prepared)
      (define conn (postgresql-prepared-statement-connection prepared))
      (define (parse-oids payload)
        (let ((n (bytevector-u16-ref-be payload 0)))
          (let loop ((offset 2) (r '()) (i 0))
            (if (= i n)
                (reverse r) ;; keep it as a list for convenience.
                (let ((oid (bytevector-u32-ref-be payload offset)))
                  (loop (+ offset 4) (cons oid r) (+ i 1)))))))
      (let ((out (postgresql-connection-sock-out conn))
            (in  (postgresql-connection-sock-in conn))
            (sql (postgresql-prepared-statement-sql prepared))
            (name (generate-unique-string conn)))
        ;; we need to send sync here so that
        ;; previous failure would be cleared. Fixes issue #2
        (postgresql-send-sync-message out)
        ;; server sends ReadyForQuery
        (postgresql-read-response in)

        (postgresql-send-parse-message out name sql '())
        (postgresql-prepared-statement-name-set! prepared name)
        ;; get description
        (postgresql-send-describe-message out name #\S)
        ;; now flush
        (postgresql-send-flush-message out)
        ;; handle responses
        (let-values (((code payload) (postgresql-read-response in)))
          (unless (char=? code #\1)
            (error "postgresql-prepared-statement: prepared statement" sql
                   code)))
        (let-values (((code payload) (postgresql-read-response in)))
          (unless (char=? code #\t)
            (error "postgresql-prepared-statement: parameter description"
                   code))
          (postgresql-prepared-statement-oids-set! prepared
                                                   (parse-oids payload)))
        (let-values (((code payload) (postgresql-read-response in)))
          (cond ((char=? code #\T)
                 (parse-row-description
                  payload
                  (lambda (vec)
                    (postgresql-prepared-statement-descriptions-set!
                     prepared vec)
                    prepared)))
                ((char=? code #\n)  ;; NoData
                 (postgresql-prepared-statement-descriptions-set! prepared #f)
                 prepared)
                (else
                 (error
                  "postgresql-prepared-statement: failed to get description"
                  code))))))

    ;; TODO
    ;; Creating prepared statement or binding parameter to it immediately
    ;; would not be a good idea. Delaying creating or binding can be done
    ;; since we are using abstraction layer of prepared statement, and it
    ;; (most likely) improves performance. (not sure yet, so we need to
    ;; measure when we implemented).
    ;; Followings are the sort of pros and cons:
    ;; Cons
    ;;  - error handling would be a bit more complex
    ;;    executing SQL or creating prepared statement?
    ;;  - extra memory space
    ;; Pros
    ;;  - unused prepared statement won't bother the server
    ;;  - less I/O operation (should improve performance as well)
    (define (postgresql-prepared-statement conn sql)
      (init-prepared-statement
       (make-postgresql-prepared-statement conn sql #f #f)))

    (define (postgresql-bind-parameters! prepared . params)
      (define conn (postgresql-prepared-statement-connection prepared))
      (let ((out (postgresql-connection-sock-out conn))
            (in  (postgresql-connection-sock-in conn))
            (name (postgresql-prepared-statement-name prepared)))
        ;; Old info but keep it for may sake.
        ;; we need to send Sync before bind a parameter in case this
        ;; binding is middle of the process (e.g. not called execute!)
        ;; otherwise PostgreSQL respond error 42P03
        ;;(postgresql-send-sync-message out)
        ;;(postgresql-read-response in)

        ;; above was (probably) needed because we didn't close portal
        ;; now we make sure portal is closed before sending Bind('B')
        ;; so it should be fine.
        (when (postgresql-prepared-statement-portal prepared)
          (postgresql-send-close-message out #\P name))
        ;; to create the same portal if needed
        (postgresql-send-bind-message out name name params '())
        (postgresql-send-flush-message out)
        ;; handle response
        (when (postgresql-prepared-statement-portal prepared)
          ;; ignore close
          (postgresql-read-response in))
        (let-values (((code payload) (postgresql-read-response in)))
          ;; BindComplete(#\2)
          (unless (char=? code #\2)
            (error "postgresql-bind-parameters! failed to execute" code)))
        (postgresql-prepared-statement-parameters-set! prepared params)
        (postgresql-prepared-statement-portal-set! prepared name)
        prepared))

    ;; CommandComplete tag (not needed...)
    #|
    (define insert-tag (string->utf8 "INSERT"))
    (define delete-tag (string->utf8 "DELETE"))
    (define update-tag (string->utf8 "UPDATE"))
    (define select-tag (string->utf8 "SELECT"))
    (define create-table-as-tag (string->utf8 "CREATE TABLE AS"))
    (define move-tag (string->utf8 "MOVE"))
    (define fetch-tag (string->utf8 "FETCH"))
    (define copy-tag (string->utf8 "COPY"))
    |#

    (define (parse-command-complete payload)
      ;; it's a bit awkward but anyway
      (define (find-start name)
        (let loop ((index (- (string-length name) 1)))
          (cond ((< index 0) #f)
                ((char=? (string-ref name index) #\space) (+ index 1))
                (else (loop (- index 1))))))
      (let* ((name (utf8->string payload))
             (start (find-start name)))
        (or (and start
                 (string->number (string-copy name start
                                              ;(- (string-length name) 1)
                                              )))
            -1)))

    (define (do-execute! prepared query)
      (define conn (postgresql-prepared-statement-connection prepared))

      (let ((out (postgresql-connection-sock-out conn))
            (in  (postgresql-connection-sock-in conn))
            (name (postgresql-prepared-statement-name prepared))
            ;; (params (postgresql-prepared-statement-parameters prepared))
            (maxnum (*postgresql-maximum-results*)))
        (postgresql-send-execute-message out name maxnum)
        (postgresql-send-flush-message out)
        ;; store it in the buffer
        (if query
            (fill-buffer query)
            ;; it must be non query so next response must be #\C
            (let loop ((r -1))
              (let-values (((code payload) (postgresql-read-response in)))
                (case code
                  ((#\C)
                   (postgresql-send-sync-message out)
                   (loop (parse-command-complete payload)))
                  ;; no more response
                  ((#\Z) r)
                  ;; i'm a bit lazy to decide how to handle this
                  ;; so let user do this.
                  ((#\H)
                   ((*postgresql-copy-data-handler*)
                    'header (->copy-data-header payload))
                   (loop r))
                  ((#\G)
                   (call-data-writer payload in out #t)
                   r)
                  ((#\d)
                   ((*postgresql-copy-data-handler*) 'data payload)
                   (loop r))
                  ((#\c)
                   ((*postgresql-copy-data-handler*) 'complete #f)
                   (loop r))
                  ((#\N)
                   (let ((code (integer->char (bytevector-u8-ref payload 0))))
                     ((*postgresql-notice-handler*) code 
                      (utf8->string payload 1))
                     (loop r)))
                  (else
                   (error "postgresql-execute!: unexpected code" code))))))))

    (define (postgresql-execute! prepared)
      (define conn (postgresql-prepared-statement-connection prepared))
      (define maxnum (*postgresql-maximum-results*))
      ;; dummy
      (unless (postgresql-prepared-statement-parameters prepared)
        (postgresql-bind-parameters! prepared))
      (let ((desc (postgresql-prepared-statement-descriptions prepared)))
        (if desc
            (let ((q (make-postgresql-query conn (make-vector maxnum)
                                            0 prepared #f)))
              (postgresql-query-descriptions-set! q desc)
              (do-execute! prepared q))
            (do-execute! prepared #f))))

    (define (postgresql-close-prepared-statement! prepared)
      (define conn (postgresql-prepared-statement-connection prepared))
      (let ((out (postgresql-connection-sock-out conn))
            (in  (postgresql-connection-sock-in conn))
            (name (postgresql-prepared-statement-name prepared)))
        (postgresql-send-sync-message out)
        (postgresql-read-response in);; discard it

        (postgresql-send-close-message out #\S name)
        ;; should be closed implicitly
        ;; (postgresql-send-close-message out #\P name)
        (postgresql-send-flush-message out)
        (let-values (((code payload) (postgresql-read-response in)))
          (unless (char=? code #\3)
            (error "postgresql-close-prepared-statement! failed to close"
                   code prepared)))
        ;; (let-values (((code payload) (postgresql-read-response in)))
        ;;   (unless (char=? code #\3)
        ;;     (error "postgresql-close-prepared-statement! failed to close"
        ;; 	   code prepared)))
        (postgresql-prepared-statement-name-set! prepared #f)))

    ;; assumes given value is properly constructed
    (define (parse-array value convert)
      ;; exclude end
      (define len (- (bytevector-length value) 1))
      (define (parse-item value offset)
        ;; don't need start
        ;; (define start (char->integer #\{))
        (define end (char->integer #\}))
        (define comma (char->integer #\,))
        (define dq (char->integer #\"))
        (define es (char->integer #\\))
        (let ((out (open-output-bytevector)))
          (let loop ((i offset) (in-dq? #f))
            (cond ((= (bytevector-u8-ref value i) end)
                   (values (get-output-bytevector out) i))
                  ((and (not in-dq?) (= (bytevector-u8-ref value i) comma))
                   (values (get-output-bytevector out) (+ i 1)))
                  ((= (bytevector-u8-ref value i) dq)
                   (loop (+ i 1) (not in-dq?)))
                  ((= (bytevector-u8-ref value i) es)
                   (write-u8 (bytevector-u8-ref value (+ i 1)) out)
                   (loop (+ i 2) in-dq?))
                  (else
                   (write-u8 (bytevector-u8-ref value i) out)
                   (loop (+ i 1) in-dq?))))))

      (let loop ((i 1) (r '()))
        (if (= i len)
            (list->vector (reverse r))
            (let-values (((item next) (parse-item value i)))
              (loop next (cons (convert item) r))))))

    (define (parse-record query payload)
      (define (read-fix payload offset size)
        (let ((end (+ offset size)))
          (values end (bytevector-copy payload offset end))))

      (define (convert value type)
        ;; for now lazy way
        (define (parse-bytea value)
          (hex-string->bytevector (utf8->string (bytevector-copy value 2))))

        (define (parse-date value)
          (->date (utf8->string value) (*postgresql-date-format*) #f))
        (define (parse-time value zone?)
          ;; It is very ambigous but seems string->date meant to be
          ;; only for *proper* date format. thus most likely only
          ;; time is not allowed. To make the code as portable as
          ;; possible, we pad 0y0m0d.
          ;; TODO should we return time-difference instead of date?
          (let ((s (string-append "00000000" (utf8->string value)))
                (fmt (string-append "~Y~m~d" (*postgresql-time-format*))))
            (->date s fmt zone?)))
        (define (parse-timestamp value zone?)
          (->timestamp (utf8->string value)
                       (*postgresql-timestamp-format*)
                       zone?))
        ;; i need something...
        ;; catalog/pg_type.h should be the one
        (case type
          ;; bigint, bigserial, integer, float
          ((20 23 23 1700 700 21 21 23)
           (string->number (utf8->string value)))
          ((701) (inexact (string->number (utf8->string value))))
          ;; time related
          ;; date
          ((1082) (parse-date value))
          ;; time, time with time zone
          ((1083 1266) (parse-time value (= type 1266)))
          ;; timestamp, timestamp with time zone
          ((1114 1184) (parse-timestamp value (= type 1184)))
          ;; character, character varying
          ((25 1042 1043 1560 1562) (utf8->string value))
          ((16) (string=? (utf8->string value) "t"))
          ((17) (parse-bytea value))
          ;; should we return UUID for Sagittarius?
          ((2950) (utf8->string value))
          ;; Arrays
          ;; char/varchar array (not sure how we can get 1002 _char)
          ((1002 1009 1014 1015) (parse-array value utf8->string))
          ((1000)
           (parse-array value (lambda (v) (string=? (utf8->string v) "t"))))
          ((1001) (parse-array value parse-bytea))
          ((1005 1007 1016 1021 1022)
           (parse-array value (lambda (v) (string->number (utf8->string v)))))
          ((1182) (parse-array value parse-date))
          ((1183 1270)
           (parse-array value (lambda (value) 
                                (parse-time value (= type 1270)))))
          ((1115 1185)
           (parse-array value (lambda (value) 
                                (parse-timestamp value (= type 1185)))))
          (else ((*postgresql-unknown-type-handler*) type value))))

      (let* ((n (bytevector-u16-ref-be payload 0))
             (vec (make-vector n #f))
             (desc (postgresql-query-descriptions query)))
        (let loop ((offset 2) (i 0))
          (if (= i n)
              vec
              (let ((size (bytevector-u32-ref-be payload offset))
                    (type (vector-ref (vector-ref desc i) 3))
                    (offset (+ offset 4)))
                ;; I hope this is the only negative number
                ;; or should we check if the most significat bit is set?
                (if (= size #xFFFFFFFF) ;; -1
                    (begin
                      (vector-set! vec i '())
                      (loop offset (+ i 1)))
                    (let-values (((offset value)
                                  (read-fix payload offset size)))
                      (vector-set! vec i (convert value type))
                      (loop offset (+ i 1)))))))))

    (define (fill-buffer query)
      (define conn (postgresql-query-connection query))
      (define in   (postgresql-connection-sock-in conn))
      (define buffer (postgresql-query-buffer query))
      (define len (vector-length buffer))
      ;; init cursor
      (postgresql-query-cursor-set! query 0)
      (let loop ((i 0))
        (if (= i len)
            ;; receive portal suspended or command complete
            (let-values (((code payload) (postgresql-read-response in)))
              (case code
                ((#\s #\C) query)
                (else
                 (error "postgresql-fetch-query!: unexpected code" code))))
            (let-values (((code payload) (postgresql-read-response in)))
              (case code
                ((#\C)
                 ;; ok shrink the buffer
                 (postgresql-query-eoq-set! query #t)
                 (postgresql-query-buffer-set! query (vector-copy buffer 0 i))
                 query)
                ((#\Z) query)
                ((#\D)
                 (vector-set! buffer i (parse-record query payload))
                 (loop (+ i 1)))
                (else
                 (error "postgresql-fetch-query!: unexpected code" code)))))))

    (define (postgresql-fetch-query! query)
      (define buffer (postgresql-query-buffer query))
      (define cursor (postgresql-query-cursor query))
      (cond ((< cursor (vector-length buffer))
             (postgresql-query-cursor-set! query (+ cursor 1))
             (vector-ref buffer cursor))
            ((postgresql-query-eoq query) #f)
            (else
             ;; first call execute again
             ;; this path must only be prepared statement query
             ;; thus query must have statement.
             (do-execute! (postgresql-query-statement query) query)
             (postgresql-fetch-query! query))))))
