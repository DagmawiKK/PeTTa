(= (peano-bootstrap $dummy)
   (progn (translatePredicate (library lib_peano.pl $path))
          (translatePredicate (consult $path))
          true))

!(peano-bootstrap ())
