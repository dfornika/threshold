# Tiny kraken2 test databases

`sarscov2_mini/` and `sarscov2_mini_b/` are identical copies (two names, so the tests can give a project more than one kraken2 database) of the SARS-CoV-2-only kraken2 database from nf-core's test datasets
(`genomics/sarscov2/genome/db/kraken2_bracken.tar.gz` in [nf-core/test-datasets](https://github.com/nf-core/test-datasets/tree/modules), MIT licence). Only the files kraken2 itself needs are kept (`hash.k2d`, `opts.k2d`, `taxo.k2d`; the bracken files are dropped).

Its taxonomy has the species _Severe acute respiratory syndrome-related coronavirus_ (taxid 694009) and, below it, SARS-CoV-2 (2697049): an expected taxid has to exist in a database's taxonomy, and this is an older one than the species-level taxids in `../manifest.csv` (which has 3418604 for the species).
Real SARS-CoV-2 reads (`tests/data/real/`) classify to it; everything else, including the synthetic reads of the default test profile, is unclassified.
