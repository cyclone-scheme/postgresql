(import (scheme base)
        (scheme write)
        (scheme process-context)
        (srfi 106)
        (cyclone test)
        (cyclone bytevector)
        (cyclone crypto md5)
	(cyclone postgresql messages)
	(cyclone postgresql conditions)
	(cyclone postgresql))

(define (run-tests)
  (test-group "PostgreSQL"

;; TODO more tests
(test-begin "Protocol messages")
(let ((out (open-output-bytevector)))
  (postgresql-send-startup-message out '(("user" . "postgres")))
  (test #u8(0 0 0 23
              0 3 0 0 
              117 115 101 114 0 
              112 111 115 116 103 114 101 115 0
              0)
        (get-output-bytevector out)))

(let ((out (open-output-bytevector)))
  (postgresql-send-password-message out "password")
  (test #u8(112 ;; #\p
            0 0 0 13
            112 97 115 115 119 111 114 100 0)
        (get-output-bytevector out)))

(let ((out (open-output-bytevector)))
  (postgresql-send-terminate-message out)
  (test #u8(88 ;; #\X
            0 0 0 4)
        (get-output-bytevector out)))
(test-end)

(test-begin "APIs")
(test-assert "connection?" 
             (postgresql-connection? 
              (make-postgresql-connection "localhost" "5432" 
                                          #f "postgres" "postgres")))
(test "condition (severity)"
      "ERROR"
      (guard (e ((postgresql-error? e)
                 (postgresql-error-severity e))
                (else #f))
        (raise-postgresql-error '((#\S . "ERROR")))))
(test-end)

(test-begin "R7RS PostgreSQL")
(define (print . args) (for-each display args) (newline))

;; user: postgres
;; pass: postgres
(define conn (make-postgresql-connection 
              "localhost" "5432" #f "postgres"
              (get-environment-variable "PASSWORD")))

 (test-group "Table creation"
 (test-assert "open connection" (postgresql-open-connection! conn))

;; TODO:
; Has to implement ssl package first
;(test-assert "try secure" (postgresql-secure-connection! conn))

 (test-assert "login" (postgresql-login! conn))

 ;; may not be there yet (causes an error if there isn't)
 (guard (e (else #t)) (postgresql-execute-sql! conn "drop table test"))
 (guard (e (else #t)) (postgresql-execute-sql! conn "drop table test2"))
 (guard (e (else #t)) (postgresql-execute-sql! conn "drop table text_text"))
 (test-assert "create tables"
              (postgresql-execute-sql! conn
                                       "create table test (id integer, name varchar(50))"))
 (test-assert "create tables"
              (postgresql-execute-sql! conn "create table test2 (guid uuid)"))
 (test-assert "create tables"
              (postgresql-execute-sql! conn "create table text_text (t text)"))
 (postgresql-execute-sql! conn "commit")
 (test-assert "terminate" (postgresql-terminate! conn))
 )

     (test-group "Query"
       (define (test-insert value)
         (let ((p (postgresql-prepared-statement 
                   conn "insert into test (id, name) values ($1, $2)")))
           (test-assert (postgresql-prepared-statement? p))
           (test "insert into test (id, name) values ($1, $2)"
                 (postgresql-prepared-statement-sql p))
           (test-assert (postgresql-bind-parameters! p 3 value))
           (test-assert 1 (postgresql-execute! p))
           (test-assert (postgresql-close-prepared-statement! p))))

       (test-assert (postgresql-open-connection! conn))

       ;; Has to implement ssl package first
       ;;(test-assert "try secure" (postgresql-secure-connection! conn))

       (test-assert (postgresql-login! conn))

       (let ((r (postgresql-execute-sql! conn "select * from test")))
         (test '#("id" "name")
               (vector-map (lambda (v) (vector-ref v 0))
                           (postgresql-query-descriptions r)))
         (test-assert (not (postgresql-fetch-query! r))))

       (postgresql-execute-sql! conn 
                                "insert into test (id, name) values (1, 'name')")
       (postgresql-execute-sql! conn 
                                "insert into test (id, name) values (2, 'test name')")
       (postgresql-execute-sql! conn 
                                "insert into test (id, name) values (-1, 'test name2')")
       (postgresql-execute-sql! conn  "commit")

       (test-insert "name")
       (test-insert '())

       (let ((r (postgresql-execute-sql! conn "select * from test")))
         (test '#(1 "name") (postgresql-fetch-query! r))
         (test '#(2 "test name") (postgresql-fetch-query! r))
         (test '#(-1 "test name2") (postgresql-fetch-query! r))
         (test '#(3 "name") (postgresql-fetch-query! r))
         (test '#(3 ()) (postgresql-fetch-query! r))
         (test-assert (not (postgresql-fetch-query! r))))

       ;; delete
       (test 5 (postgresql-execute-sql! conn "delete from test"))

       ;; input value error
       (let ((p (postgresql-prepared-statement
                 conn "insert into test2 (guid) values ($1)")))
         (guard (e (else (postgresql-close-prepared-statement! p)
                         (test-assert "ok" #t)))
           (postgresql-bind-parameters! p "not a uuid")
           (postgresql-execute! p)
           (test-assert "must be an input check" #f))))

     (test-group "Maximum rows"
       ;; max column test
       (let ((p (postgresql-prepared-statement 
                 conn "insert into test (id, name) values ($1, $2)")))
         (let loop ((i 0))
           (unless (= i 100)
             (postgresql-bind-parameters! p i "name")
             (postgresql-execute! p)
             (loop (+ i 1))))
         (postgresql-close-prepared-statement! p))
       (postgresql-execute-sql! conn "commit")

       (let ((p (postgresql-prepared-statement 
                 conn "select * from test where name = $1")))
         (postgresql-bind-parameters! p "name")
         (let ((q (postgresql-execute! p)))
           ;; skip first 50
           (do ((i 0 (+ i 1)))
               ((= i 50))
             (postgresql-fetch-query! q))
           ;; 51
           (test '#(50 "name") (postgresql-fetch-query! q))
           ;; skip next 48
           (do ((i 0 (+ i 1)))
               ((= i 48))
             (postgresql-fetch-query! q))
           (test-equal "99" '#(99 "name") (postgresql-fetch-query! q))
           (test-assert (not (postgresql-fetch-query! q))))
         (postgresql-close-prepared-statement! p))

       (let ((q (postgresql-execute-sql! conn "select * from test")))
         (do ((i 0 (+ i 1)))
             ((= i 60))
           (postgresql-fetch-query! q))
         (test-equal "60" '#(60 "name") (postgresql-fetch-query! q))))

     (test-group "Non existing table"
       (postgresql-execute-sql! conn "drop table test")
       (postgresql-execute-sql! conn "commit")

       (guard (e (else (test-assert (error-object? e))))
         (postgresql-execute-sql! conn "drop table test"))

       ;; issue #2 re-creation of prepared statement
       ;; ? is not a valid placeholder in PostgreSQL
       (guard (e (else (test-assert (error-object? e))))
         (let ((ps (postgresql-prepared-statement 
                    conn "select * from foo where a = ?")))
           (postgresql-close-prepared-statement! ps)
           (test-assert "? is not a valid syntax" #f)))
       ;; this hanged
       (guard (e (else (test-assert (error-object? e))))
         (let ((ps (postgresql-prepared-statement 
                    conn "select * from foo where a = ?")))
           (postgresql-close-prepared-statement! ps)
           (test-assert "Shouldn't be here" #f))))

     ;; Japanese text
     (test-group "UTF-8"
       (let ((p (postgresql-prepared-statement
                 conn "insert into text_text (t) values ($1)"))
             (msg "日本語テスト"))
         (postgresql-bind-parameters! p msg)
         (postgresql-execute! p)
         (postgresql-close-prepared-statement! p)
         (let ((r (postgresql-execute-sql! conn "select t from text_text")))
           (test `#(,msg) (postgresql-fetch-query! r)))))

     ;; terminate and close connection
     (postgresql-terminate! conn)

(test-end)
))

(run-tests)
