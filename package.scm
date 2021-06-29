(package
 (name postgresql)
 (version "0.1.0")
 (license "BSD")
 (authors "Takashi Kato")
 (maintainers "Justin Ethier")
 (description "PostgreSQL socket frontend interface library written in pure R7RS Scheme.")
 (tags "database" "sql" "networking")
 (docs "https://github.com/cyclone-scheme/cyclone-winds/wiki/postgresql")
 (test "test.scm")
 (dependencies (bytevector md5))
 (test-dependencies ())
 (foreign-dependencies ())
 (library
  (name (cyclone postgresql))
  (description "Wrap library"))
 (library
  (name (cyclone postgresql apis))
  (description "API - main procedures"))
 (library
  (name (cyclone postgresql conditions))
  (description "Conditions library"))
 (library
  (name (cyclone postgresql messages))
  (description "Messages library"))
 (library
  (name (cyclone postgresql buffer))
  (description "Buffer library"))
 (library
  (name (cyclone postgresql misc io))
  (description "Input/output library"))
 (library
  (name (cyclone postgresql misc ssl))
  (description "SSL library - to be done")))
