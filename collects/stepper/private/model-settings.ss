(module model-settings mzscheme
  (require "mred-extensions.ss"
           (prefix p: (lib "pconvert.ss"))
           "my-macros.ss")
  
  (provide

   ; namespace queries
   check-global-defined
   global-lookup
   
   ; settings queries
   true-false-printed?
   constructor-style-printing?
   abbreviate-cons-as-list?
   ;special-function?
   
   ;print-convert
   print-convert)
  
  (make-contract-checker SYMBOL symbol?)
   
  (define (true-false-printed?) (p:booleans-as-true/false))
  (define (constructor-style-printing?) (p:constructor-style-printing))
  (define (abbreviate-cons-as-list?) (p:abbreviate-cons-as-list))
  
  (define check-global-defined
    (checked-lambda ((identifier SYMBOL))
    (with-handlers
        ([exn:variable? (lambda args #f)])
      (global-lookup identifier)
      #t)))
  
  (define global-lookup
    (checked-lambda ((identifier SYMBOL))
      (namespace-variable-binding identifier)))
  
   (define (print-convert val)
     (parameterize ([p:current-print-convert-hook
                     (lambda (v basic-convert sub-convert)
                       (if (image? v)
                           v
                           (basic-convert v)))])
       (p:print-convert val)))
   
  )