(module model mzscheme
  (require (lib "mred.ss" "mred")
           (prefix p: (lib "print-convert.ss"))
           (prefix i: "model-input.ss")
           (prefix a: "annotate.ss")
           (prefix r: "reconstruct.ss")
           "shared.ss")
 
  
  (provide
   check-pre-defined-var
   check-global-defined
   global-lookup
   true-false-printed?
   constructor-style-printing?
   abbreviate-cons-as-list?
   special-function?
   image?
   print-convert
   go)
  
;  (import [i : stepper:model-input^]
;          mred^
;          [z : zodiac:system^]
;          [d : drscheme:export^]
;          [p : mzlib:print-convert^]
;          [e : zodiac:interface^]
;          [a : stepper:annotate^]
;          [r : stepper:reconstruct^]
;          stepper:shared^)
  
  (define image? i:image?)
  
  ; my-assq is like assq but it only returns the second element of the list. This
  ; is the way it should be, I think.
  (define (my-assq assoc-list value)
    (cond [(null? assoc-list) #f]
          [(eq? (caar assoc-list) value) (cadar assoc-list)]
          [else (my-assq (cdr assoc-list) value)]))
  
  (define user-pre-defined-vars #f)
  
  (define (check-pre-defined-var identifier)
    (memq identifier user-pre-defined-vars))
  
  (define user-namespace #f)
  
  (define (check-global-defined identifier)
    (with-handlers
        ([exn:variable? (lambda args #f)])
      (global-lookup identifier)
      #t))
  
  (define (global-lookup identifier)
    (parameterize ([current-namespace user-namespace])
      (global-defined-value identifier)))
  
  (define finished-exprs null)
  
  (define current-expr #f)
  (define packaged-envs a:initial-env-package)
  
  (define user-eventspace (make-eventspace))
  
  ;; user eventspace management
  

  
  ;; start user thread going
  (send-to-other-eventspace
   user-eventspace
   suspend-user-computation)
  
  (define user-primitive-eval #f)
  (define user-vocabulary #f)

  (define reader 
    (z:read i:text-stream
            (z:make-location 1 1 0 "stepper-text")))
  
  (send-to-user-eventspace
   (lambda ()
     (set! user-primitive-eval (current-eval))
     (d:basis:initialize-parameters (make-custodian) i:settings)
     (set! user-namespace (current-namespace))
     (set! user-pre-defined-vars (map car (make-global-value-list)))
     (set! user-vocabulary (d:basis:current-vocabulary))
     (set! par-true-false-printed (p:booleans-as-true/false))
     (set! par-constructor-style-printing (p:constructor-style-printing))
     (set! par-abbreviate-cons-as-list (p:abbreviate-cons-as-list))
     (set! par-special-functions (map (lambda (name) (list name (global-defined-value name)))
                                      special-function-names))
     (semaphore-post stepper-return-val-semaphore)))
  (semaphore-wait stepper-return-val-semaphore)
  
  (define print-convert
    (let ([print-convert-result 'not-a-real-value])    
      (lambda (val)
        (send-to-user-eventspace
         (lambda ()
           (set! print-convert-result
                 (parameterize ([p:current-print-convert-hook
                                 (lambda (v basic-convert sub-convert)
                                   (if (image? v)
                                       v
                                       (basic-convert v)))])
                   (p:print-convert val)))
           (semaphore-post stepper-return-val-semaphore)))
        (semaphore-wait stepper-return-val-semaphore)
        print-convert-result)))
  
  (define (read-next-expr)
    (send-to-user-eventspace
     (lambda ()
       (let/ec k
         (let ([exception-handler (make-exception-handler k)])
           (d:interface:set-zodiac-phase 'reader)
           (let* ([new-expr (with-handlers
                                ((exn:read? exception-handler))
                              (reader))])
             (if (z:eof? new-expr)
                 (begin
                   (send-to-drscheme-eventspace
                    (lambda ()
                      (i:receive-result (make-finished-result finished-exprs))))
                   'finished)
                 (let* ([new-parsed (if (z:eof? new-expr)
                                        #f
                                        (begin
                                          (d:interface:set-zodiac-phase 'expander)
                                          (with-handlers
                                              ((exn:syntax? exception-handler))
                                            (z:scheme-expand new-expr 'previous user-vocabulary))))])
                   (let*-values ([(annotated-list envs) (a:annotate (list new-expr) (list new-parsed) packaged-envs break 
                                                                    'foot-wrap)]
                                 [(annotated) (car annotated-list)])
                     (set! packaged-envs envs)
                     (set! current-expr new-parsed)
                     (check-for-repeated-names new-parsed exception-handler)
                     (let ([expression-result
                            (parameterize ([current-exception-handler exception-handler])
                              (user-primitive-eval annotated))])
                       (send-to-drscheme-eventspace
                        (lambda ()
                          (add-finished-expr expression-result)
                          (read-next-expr)))))))))))))
  
  (define (check-for-repeated-names expr exn-handler)
    (with-handlers
        ([exn:user? exn-handler]
         [exn:syntax? exn-handler])
      (when (z:define-values-form? expr)
        (for-each (lambda (name) 
                    (when (check-global-defined name)
                      (e:static-error "define" 'kwd:define expr
                                      "name is already bound: ~s" name)))
                  (map z:varref-var (z:define-values-form-vars expr))))))
  
  (define (add-finished-expr expression-result)
    (let ([reconstructed (r:reconstruct-completed current-expr expression-result)])
      (set! finished-exprs (append finished-exprs (list reconstructed)))))
  
  (define held-expr-list no-sexp)
  (define held-redex-list no-sexp)
  
  ; if there's a sexp which _doesn't_ contain a highlight in between two that do, we're in trouble.
  
  (define (redivide exprs)
    (letrec ([contains-highlight-placeholder
              (lambda (expr)
                (if (pair? expr)
                    (or (contains-highlight-placeholder (car expr))
                        (contains-highlight-placeholder (cdr expr)))
                    (eq? expr highlight-placeholder)))])
      (let loop ([exprs exprs] [mode 'before])
        (cond [(null? exprs) 
               (if (eq? mode 'before)
                   (error 'redivide "no sexp contained the highlight-placeholder.")
                   (values null null null))]
              [(contains-highlight-placeholder (car exprs))
               (if (eq? mode 'after)
                   (error 'redivide "highlighted sexp when already in after mode")
                   (let-values ([(before during after) (loop (cdr exprs) 'during)])
                     (values before (cons (car exprs) during) after)))]
              [else
               (case mode
                 ((before) 
                  (let-values ([(before during after) (loop (cdr exprs) 'before)])
                    (values (cons (car exprs) before) during after)))
                 ((during after) 
                  (let-values ([(before during after) (loop (cdr exprs) 'after)])
                    (values before during (cons (car exprs) after)))))]))))

;(redivide `(3 4 (+ (define ,highlight-placeholder) 13) 5 6))
;(values `(3 4) `((+ (define ,highlight-placeholder) 13)) `(5 6))
;
;(redivide `(,highlight-placeholder 5 6))
;(values `() `(,highlight-placeholder) `(5 6))
;
  ;(redivide `(4 5 ,highlight-placeholder ,highlight-placeholder))
;(values `(4 5) `(,highlight-placeholder ,highlight-placeholder) `())
;
;(printf "will be errors:~n")
;(equal? (redivide `(1 2 3 4))
;        error-value)
;
;(equal? (redivide `(1 2 ,highlight-placeholder 3 ,highlight-placeholder 4 5))
;        error-value)
 
  
  (define (break mark-set key break-kind returned-value-list)
    (let ([mark-list (continuation-mark-set->list mark-set key)])
      (let ([double-redivide
             (lambda (finished-exprs new-exprs-before new-exprs-after)
               (let*-values ([(before current after) (redivide new-exprs-before)]
                             [(before-2 current-2 after-2) (redivide new-exprs-after)]
                             [(_) (unless (and (equal? before before-2)
                                               (equal? after after-2))
                                    (error 'break "reconstructed before or after defs are not equal."))])
                 (values (append finished-exprs before) current current-2 after)))]
            [reconstruct-helper
             (lambda (finish-thunk)
               (send-to-drscheme-eventspace
                (lambda ()
                  (let* ([reconstruct-pair
                          (r:reconstruct-current current-expr mark-list break-kind returned-value-list)]
                         [reconstructed (car reconstruct-pair)]
                         [redex-list (cadr reconstruct-pair)])
                    (finish-thunk reconstructed redex-list)))))])
        (case break-kind
          [(normal-break)
           (when (not (r:skip-redex-step? mark-list))
             (reconstruct-helper 
              (lambda (reconstructed redex-list)
                (set! held-expr-list reconstructed)
                (set! held-redex-list redex-list)
                (continue-user-computation)))
             (suspend-user-computation))]
          [(result-break)
           (when (if (not (null? returned-value-list))
                     (not (r:skip-redex-step? mark-list))
                     (and (not (eq? held-expr-list no-sexp))
                          (not (r:skip-result-step? mark-list))))
             (reconstruct-helper 
              (lambda (reconstructed reduct-list)
                ;              ; this invariant (contexts should be the same)
                ;              ; fails in the presence of unannotated code.  For instance,
                ;              ; currently (map my-proc (cons 3 empty)) goes to
                ;              ; (... <body-of-my-proc> ...), where the context of the first one is
                ;              ; empty and the context of the second one is (... ...).
                ;              ; so, I'll just disable this invariant test.
                ;              (when (not (equal? reconstructed held-expr-list))
                ;                (error 'reconstruct-helper
                ;                                  "pre- and post- redex/uct wrappers do not agree:~nbefore: ~a~nafter~a"
                ;                                  held-expr-list reconstructed))
                (let ([result
                       (if (not (eq? held-expr-list no-sexp))
                           (let*-values 
                               ([(new-finished current-pre current-post after) 
                                 (double-redivide finished-exprs held-expr-list reconstructed)])
                             (make-before-after-result new-finished current-pre held-redex-list current-post reduct-list after))
                           (let*-values
                               ([(before current after) (redivide reconstructed)])
                             (make-before-after-result (append finished-exprs before) `(,highlight-placeholder) `(...)
                                                       current reduct-list after)))])
                  (set! held-expr-list no-sexp)
                  (set! held-redex-list no-sexp)
                  (i:receive-result result))))
             (suspend-user-computation))]
          [(double-break)
           ; a double-break occurs at the beginning of a let's evaluation.
           (send-to-drscheme-eventspace
            (lambda ()
              (let* ([reconstruct-quadruple
                      (r:reconstruct-current current-expr mark-list break-kind returned-value-list)])
                (when (not (eq? held-expr-list no-sexp))
                  (error 'break-reconstruction
                         "held-expr-list not empty when a double-break occurred"))
                (let*-values 
                    ([(new-finished current-pre current-post after) (double-redivide finished-exprs 
                                                                                     (list-ref reconstruct-quadruple 0) 
                                                                                     (list-ref reconstruct-quadruple 2))])
                  (i:receive-result (make-before-after-result new-finished
                                                              current-pre
                                                              (list-ref reconstruct-quadruple 1)
                                                              current-post
                                                              (list-ref reconstruct-quadruple 3)
                                                              after))))))
           (suspend-user-computation)]
          [(late-let-break)
           (send-to-drscheme-eventspace
            (lambda ()
              (let ([new-finished (r:reconstruct-current current-expr mark-list break-kind returned-value-list)])
                (set! finished-exprs (append finished-exprs new-finished))
                (continue-user-computation))))
           (suspend-user-computation)]
          [else (error 'break "unknown label on break")]))))
  
  (define (handle-exception exn)
    (if (not (eq? held-expr-list no-sexp))
        (let*-values
            ([(before current after) (redivide held-expr-list)])
          (i:receive-result (make-before-error-result (append finished-exprs before) 
                                                      current held-redex-list (exn-message exn) after)))
        (begin
          (i:receive-result (make-error-result finished-exprs (exn-message exn))))))
  
  (define (make-exception-handler k)
    (lambda (exn)
      (send-to-drscheme-eventspace
       (lambda ()
         (handle-exception exn)))
      (k)))

  (define (go)
    
    (binding-index-reset)
    
    
    ; start the ball rolling with a "fake" user computation
    (send-to-user-eventspace
     (lambda ()
       (suspend-user-computation)
       (send-to-drscheme-eventspace
        read-next-expr)))
    
    ; result of invoking stepper-instance : (->)
    continue-user-computation))