# Test-only StoreKit signing chain

These certificates and the leaf key exist only so the server checks can sign
fake App Store transactions. They are not Apple's and nothing trusts them
unless `PHOTOCORE_STOREKIT_TEST_ROOT` points at `root.der`, which only the
checks and local development do. The root and intermediate private keys were
deleted after signing.

The leaf and intermediate carry Apple's marker extensions
(1.2.840.113635.100.6.11.1 and 1.2.840.113635.100.6.2.1) so the same code path
that checks real App Store transactions is exercised.
