# postgresql

## Index 
- [Intro](#Intro)
- [Dependencies](#Dependencies)
- [Test dependencies](#Test-dependencies)
- [Foreign dependencies](#Foreign-dependencies)
- [API](#API)
- [Examples](#Examples)
- [Author(s)](#Author(s))
- [Maintainer(s)](#Maintainer(s))
- [Version](#Version) 
- [License](#License) 
- [Tags](#Tags) 

## Intro 
This is a PostgreSQL socket frontend interface library written in pure R7RS Scheme. Original code can be found [here](https://github.com/ktakashi/r7rs-postgresql).

## Dependencies 
`bytevector` `md5`

## Test-dependencies 
None

## Foreign-dependencies 
None

## API 

### Library

- `(postgresql)` The library provides high level APIs to communicate
  with PostgreSQL.

### Procedures

- `(postgresql-connection? obj)`

  Returns `#t` if _obj_ is an PostgreSQL connection object.


-  `(make-postgresql-connection host port database username password)`

   `database` can be `#f`.

   All arguments must be a string except `database`. Creates a
   PostgreSQL connection. At this moment, the connection to the server
   is *not* established.


- `(postgresql-open-connection! conn)`

  Establishes a connection with specified _conn_ object.


- `(postgresql-login! conn)`

  Logging in to the PostgreSQL server.


- `(postgresql-terminate! conn)`

  Terminates the session and disconnects from the server.


- `(postgresql-prepared-statement? obj)`

  Return `#t` if _obj_ is a PostgreSQL prepared statement.


- `(postgresql-prepared-statement conn sql)`

  Creates a prepared statement object.


- `(postgresql-close-prepared-statement! prepared-statement)`

  Closes the prepared statement _prepared-statement_.


- `(postgresql-bind-parameters! prepared-statement . params)`

  Binds parameter _params_ to given _prepared-statement_.


- `(postgresql-execute! prepared-statement)`

  Executes the given _prepared-statement_ and returns either
  PostgreSQL query object for SELECT statement or affected row count.

  To retrieve the result, use the `postgresql-fetch-query!` procedure.


- `(postgresql-query? obj)`

  Returns `#t` if _obj_ is a PostgreSQL query object.


- `(postgresql-execute-sql! conn sql)`

  Executes the given _sql_ statement. If _sql_ is a select statement
  then the value returned is a PostgreSQL query object. Otherwise
  `#t`.  This procedure retrieves all results in one go if _sql_ is a
  SELECT statement. So it may cause memory explosion if the result set
  is too big.


- `(postgresql-fetch-query! query)`

  Fetch a row as a vector. If no more data are available, then returns
  `#f`.


- `(postgresql-start-transaction! conn mode)`

  Issue `START TRANSACTION` statement to start a transaction.  _mode_
  specifies how the transation should be.

  The argument _mode_ must be either a PostgreSQL transaction mode
  object or `#f`.


- `(postgresql-transaction-mode alist)`

  Creates a PostgreSQL transaction mode object. The _alist_ specifies
  how the transaction mode is created. It may have the following
  symbols as its key.

  - `isolation-level`
  - `access-mode`
  - `deferrable`

  Each key must have one of the followings:

  For `isolation-level`:

  - Variable: `postgresql-isolation-level-serializable`
  - Variable: `postgresql-isolation-level-repeatable-read`
  - Variable: `postgresql-isolation-level-read-committed`
  - Variable: `postgresql-isolation-level-read-uncommitted`

  For `access-mode`:

  - Variable: `postgresql-access-mode-read-write`
  - Variable: `postgresql-access-mode-read-only`

  For `deferrable`:

  - Variable: `postgresql-deferrable-on`
  - Variable: `postgresql-deferrable-off`


- `(postgresql-commit! conn)`

  Issue `COMMIT` statement.


- `(postgresql-rollback! conn)`

  Issue `ROLLBACK` statement.

### Parameters
- `*postgresql-maximum-results*`

  Configuration parameter for how many result it should fetch. Default
  value is 50.


- `*postgresql-copy-data-handler*`

  Handler of COPY to stdout command. The value must be a procedure and
  takes 2 arguments, data type and data. The data type should be one
  of the the following symbols:

  - header
  - data
  - complete

  When the data type is `header` then the given data is a list of data
  information. It contains 3 elements, the format of overall COPY
  command, 0 is textual, 1 is binary.

  When the data type is `data` then the given data is a bytevector
  whose content is the result of COPY command.

  When the data type is `complete` then the given data is `#f`. This
  indicates the COPY command is done.


- `*postgresql-write-data-handler*`

 Handler of COPY from stdin command. The value must be a procedure and
 take 2 arguments, data type and data. The data type could be one of
 the following symbols;

 - header
 - data
 - complete

  When the data type is `header` then the given data is a list of data
  information. It contains 3 elements, the format of overall COPY
  command, 0 is textual, 1 is binary.

  When the data type is `data` then the given data is a `#f`. When
  there is no more data to send, then the handler must return `#f`
  otherwise it would go into inifinite loop.

  When the data type is `complete` then the given data is `#t`. This
  indicates the COPY command is done.


  These handlers are currently a thin wrapper of the COPY
  command. Using them, users need to know about how the data is
  sent. For more detail, please refer the PostgreSQL manual.

- `*postgresql-unknown-type-handler*`

  Handler of unknown type, which is the library default couldn't
  handle converting the value according to the type identifier. The
  value must be aprocedure and take 2 arguments; _type_ and
  _value_. The _type_ is an integer which represents PostgreSQL
  internal type defined in `catalog/pg_type.h` header file of
  PostgreSQL source. The _value_ is a raw value of SQL query,
  bytevector.

## Low level APIs

TBD

## Data conversion

Data conversion is done automatically by high level APIs. The following table
describes how it's done.

| PostgreSQL type |     Scheme type      |
|:--------------- | --------------------:|
|   Integers      |   Number             |
|   Float         |   Inexact number     |
|   Characters    |   String             |
|   Date          |   SRFI-19 date       |
|   Time          |   SRFI-19 date       |
|   Timestamp     |   SRFI-19 time       |
|   UUID          |   String             |

_Note_: If the implementation doesn't support SRFI-19, the scheme type
will be string.


## Examples

```scheme
(import (scheme base)
	(scheme write)
	(cyclone postgresql))

(define (print . args) (for-each display args) (newline))

;; user: postgres
;; pass: postgres
(define conn (make-postgresql-connection 
	      "localhost" "5432" #f "postgres" "postgres"))

(print "open connection")
;; open the connection
(postgresql-open-connection! conn)

;; login
(print "login")
(postgresql-login! conn)

(print "create tables")
;; may not be there yet (causes an error if there isn't)
(guard (e (else #t)) (postgresql-execute-sql! conn "drop table test"))
(guard (e (else (print (error-object-message e))))
  (postgresql-execute-sql! conn
    "create table test (id integer, name varchar(50))"))
(postgresql-terminate! conn)

(postgresql-open-connection! conn)
(postgresql-login! conn)

(print "simple query")
(let ((r (postgresql-execute-sql! conn "select * from test")))
  (print (postgresql-query-descriptions r))
  (print (postgresql-fetch-query! r)))

(postgresql-execute-sql! conn 
  "insert into test (id, name) values (1, 'name')")
(postgresql-execute-sql! conn 
  "insert into test (id, name) values (2, 'test name')")
(postgresql-execute-sql! conn 
  "insert into test (id, name) values (-1, 'test name2')")
(postgresql-execute-sql! conn  "commit")

(print "insert with prepared statement")
(let ((p (postgresql-prepared-statement 
	  conn "insert into test (id, name) values ($1, $2)")))
  (print (postgresql-prepared-statement-sql p))
  (print (postgresql-bind-parameters! p 3 "name"))
  (let ((q (postgresql-execute! p)))
    (print q))
  (postgresql-close-prepared-statement! p))

(let ((p (postgresql-prepared-statement 
	  conn "insert into test (id, name) values ($1, $2)")))
  (print (postgresql-prepared-statement-sql p))
  (print (postgresql-bind-parameters! p 3 '()))
  (let ((q (postgresql-execute! p)))
    (print q))
  (postgresql-close-prepared-statement! p))

(print "select * from test")
(let ((r (postgresql-execute-sql! conn "select * from test")))
  (print (postgresql-query-descriptions r))
  (print (postgresql-fetch-query! r))
  (print (postgresql-fetch-query! r))
  (print (postgresql-fetch-query! r))
  (print (postgresql-fetch-query! r))
  (print (postgresql-fetch-query! r)))

(let ((p (postgresql-prepared-statement 
	  conn "select * from test where name = $1")))
  (print (postgresql-prepared-statement-sql p))
  (print (postgresql-bind-parameters! p "name"))
  (let ((q (postgresql-execute! p)))
    (print q)
    (print (postgresql-fetch-query! q))
    (print (postgresql-fetch-query! q)))
  (postgresql-close-prepared-statement! p))

(let ((p (postgresql-prepared-statement 
	  conn "select * from test where id = $1")))
  (print (postgresql-prepared-statement-sql p))
  (print (postgresql-bind-parameters! p 1))
  (let ((q (postgresql-execute! p)))
    (print q)
    (print (postgresql-fetch-query! q))
    (print (postgresql-fetch-query! q)))
  (postgresql-close-prepared-statement! p))

;; delete
(print "delete")
(print (postgresql-execute-sql! conn "delete from test"))

;; max column test
(let ((p (postgresql-prepared-statement 
	  conn "insert into test (id, name) values ($1, $2)")))
  (let loop ((i 0))
    (unless (= i 100)
      (postgresql-bind-parameters! p i "name")
      (postgresql-execute! p)
    (loop (+ i 1))))
  (postgresql-close-prepared-statement! p))

(let ((p (postgresql-prepared-statement 
	  conn "select * from test where name = $1")))
  (print (postgresql-prepared-statement-sql p))
  (print (postgresql-bind-parameters! p "name"))
  (let ((q (postgresql-execute! p)))
    ;; skip first 50
    (print "skip 50")
    (do ((i 0 (+ i 1)))
	((= i 50))
      (postgresql-fetch-query! q))
    ;; 51
    (print "get 51st")
    (print (postgresql-fetch-query! q))
    ;; skip next 50
    (do ((i 0 (+ i 1)))
	((= i 50))
      (postgresql-fetch-query! q))
    (print (postgresql-fetch-query! q)))
  (postgresql-close-prepared-statement! p))

(let ((q (postgresql-execute-sql! conn "select * from test")))
  (do ((i 0 (+ i 1)))
      ((= i 60))
    (postgresql-fetch-query! q))
  (print (postgresql-fetch-query! q)))

(postgresql-execute-sql! conn "drop table test")

(print "droping non existing table")
(guard (e (else (print (error-object-message e))))
  (postgresql-execute-sql! conn "drop table test"))

;; issue #2 re-creation of prepared statement
;; ? is not a valid placeholder in PostgreSQL
(guard (e (else (print e)))
  (let ((ps (postgresql-prepared-statement 
             conn "select * from foo where a = ?")))
    (print ps)
    (postgresql-close-prepared-statement! ps)))
;; this hanged
(guard (e (else (print e)))
  (let ((ps (postgresql-prepared-statement 
             conn "select * from foo where a = ?")))
    (print ps)
    (postgresql-close-prepared-statement! ps)))

;; terminate and close connection
(print "terminate")
(postgresql-terminate! conn)
```

```scheme
;; example how to do copy data.

(import (scheme base)
	(scheme write)
	(postgresql))

(define conn (make-postgresql-connection 
	      "localhost" "5432" #f "postgres" "postgres"))

(define (print . args) (for-each display args) (newline))

(postgresql-open-connection! conn)
(postgresql-login! conn)

(guard (e (else #t)) (postgresql-execute-sql! conn "drop table test"))
(guard (e (else (print (error-object-message e))))
  (postgresql-execute-sql! conn
    "create table test (id integer not null primary key, name varchar(50))"))

(define (copy-handler type payload)
  (case type
    ((header) (write payload) (newline))
    ((data)   (display (utf8->string payload)))))

(define (write-handler n)
  (let ((count 0))
    (lambda (type data)
      (case type
	((data)
	 (set! count (+ count 1))
	 (if (not (= count n)) 
	     (string->utf8 (string-append (number->string count)
					  "\tdata\n"))
	     #f))))))

(*postgresql-copy-data-handler* copy-handler)
(*postgresql-write-data-handler* (write-handler 100))

(guard (e (else (print e)))
  (print (postgresql-execute-sql! conn  "copy test from stdin")))

(print (postgresql-execute-sql! conn  "copy test to stdout with delimiter ','"))

(postgresql-terminate! conn)
```

## Author(s)
Takashi Kato <ktakashi at ymail dot com>

## Maintainer(s) 
Arthur Maciel <arthuramciel at gmail dot com>

## Version 
0.1

## License 
Copyright 2014-2015 Takashi Kato. Code released under the BSD-style license.
See [COPYING](COPYING).

## Tags 
database
