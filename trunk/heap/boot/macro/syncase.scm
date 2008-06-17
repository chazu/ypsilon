;;; Ypsilon Scheme System
;;; Copyright (c) 2004-2008 Y.FUJITA, LittleWing Company Limited.
;;; See license.txt for terms and conditions of use.

;; memo:
;; (lookup-lexical-name)
;;   local macro bound to unique symbol generated by (generate-local-macro-symbol). It may used for lexical name.
;; (unrename-syntax)
;;   apply unrename-syntax to literals, patterns, and templates. It make expanded code free from environment.
;; (datum->syntax)
;;   if call (datum->syntax ...) on macro expansion, (syntax-object-renames template-id) should be nil.
;;   if call (datum->syntax ...) on transformer evaluation, (syntax-object-renames template-id) should be alist.

(set-top-level-value! '.patvars '())

(define make-syntax-object    (lambda (form renames lexname) (tuple 'type:syntax form renames lexname)))
(define syntax-object-expr    (lambda (obj) (tuple-ref obj 1)))
(define syntax-object-renames (lambda (obj) (tuple-ref obj 2)))
(define syntax-object-lexname (lambda (obj) (tuple-ref obj 3)))

(define wrapped-syntax-object?
  (lambda (datum)
    (eq? (tuple-ref datum 0) 'type:syntax)))

(define lookup-lexical-name
  (lambda (id env)
    (let ((deno (env-lookup env id)))
      (cond ((renamed-id? deno) deno)
            ((and (macro? deno) (assq deno env)) => cdr)
            (else id)))))

(define contain-wrapped-syntax-object?
  (lambda (lst)
    (let loop ((lst lst))
      (cond ((pair? lst)
             (or (loop (car lst)) (loop (cdr lst))))
            ((vector? lst)
             (let loop2 ((i (- (vector-length lst) 1)))
               (and (>= i 0)
                    (or (loop (vector-ref lst i))
                        (loop2 (- i 1))))))
            (else
             (wrapped-syntax-object? lst))))))

(define contain-non-id-wrapped-syntax-object?
  (lambda (lst)
    (let loop ((lst lst))
      (cond ((pair? lst)
             (or (loop (car lst)) (loop (cdr lst))))
            ((vector? lst)
             (let loop2 ((i (- (vector-length lst) 1)))
               (and (>= i 0)
                    (or (loop (vector-ref lst i))
                        (loop2 (- i 1))))))
            ((identifier? lst) #f)
            (else
             (wrapped-syntax-object? lst))))))

(define unwrap-syntax
  (lambda (expr)
    (cond ((contain-non-id-wrapped-syntax-object? expr)
           (let ((renames
                  (let ((ht (make-core-hashtable)))
                    (let loop ((lst expr))
                      (cond ((pair? lst)
                             (loop (car lst))
                             (loop (cdr lst)))
                            ((vector? lst)
                             (for-each loop (vector->list lst)))
                            ((identifier? lst)
                             (let ((rename (syntax-object-renames lst)))
                               (or (null? rename)
                                   (core-hashtable-contains? ht (car rename))
                                   (core-hashtable-set! ht (car rename) (cdr rename)))))
                            ((wrapped-syntax-object? lst)
                             (for-each (lambda (a)
                                         (or (core-hashtable-contains? ht (car a))
                                             (core-hashtable-set! ht (car a) (cdr a))))
                                       (syntax-object-renames lst))
                             (loop (syntax-object-expr lst)))))
                    (core-hashtable->alist ht))))
             (let loop ((lst expr))
               (cond ((pair? lst)
                      (let ((a (loop (car lst))) (d (loop (cdr lst))))
                        (cond ((and (eq? a (car lst)) (eq? d (cdr lst))) lst)
                              (else (cons a d)))))
                     ((symbol? lst)
                      (make-syntax-object lst (or (assq lst renames) '()) #f))
                     ((wrapped-syntax-object? lst)
                      (cond ((identifier? lst) lst)
                            (else (loop (syntax-object-expr lst)))))
                     ((vector? lst)
                      (list->vector (map loop (vector->list lst))))
                     (else lst)))))
          (else expr))))

(define unrename-syntax
  (lambda (form env)

    (define identical-global-macro?
      (lambda (deno id)
        (and (macro? deno)
             (eq? deno (core-hashtable-ref (current-macro-environment) id #f)))))

    (let loop ((lst form))
      (cond ((pair? lst)
             (if (annotated? lst)
                 (annotate (cons (loop (car lst)) (loop (cdr lst))) lst)
                 (cons (loop (car lst)) (loop (cdr lst)))))
            ((symbol? lst)
             (let ((deno (env-lookup env lst))
                   (id (original-id lst)))
               (cond ((special? deno) id)
                     ((identical-global-macro? deno id) id)
                     (else lst))))
            ((vector? lst)
             (list->vector (map loop (vector->list lst))))
            (else lst)))))

(set-top-level-value! '.flatten-syntax
  (lambda (expr)
    (let ((ht (make-core-hashtable)))
      (let ((expr
             (let loop ((lst expr))
               (cond ((pair? lst)
                      (let ((a (loop (car lst))) (d (loop (cdr lst))))
                        (cond ((and (eq? a (car lst)) (eq? d (cdr lst))) lst)
                              (else (cons a d)))))
                     ((vector? lst)
                      (list->vector (map loop (vector->list lst))))
                     ((identifier? lst)
                      (let ((rename (syntax-object-renames lst)))
                        (or (null? rename)
                            (or (core-hashtable-contains? ht (car rename))
                                (core-hashtable-set! ht (car rename) (cdr rename)))))
                      (syntax-object-expr lst))
                     ((wrapped-syntax-object? lst)
                      (for-each (lambda (a)
                                  (or (core-hashtable-contains? ht (car a))
                                      (core-hashtable-set! ht (car a) (cdr a))))
                                (syntax-object-renames lst))
                      (loop (syntax-object-expr lst)))
                     (else lst)))))
        (values expr (core-hashtable->alist ht))))))

(set-top-level-value! '.syntax-dispatch
  (lambda (patvars form lites . lst)

    (define match
      (lambda (form pat)
        (and (match-pattern? form pat lites)
             (bind-pattern form pat lites '()))))

    (let ((form (unwrap-syntax form)))
      (let loop ((lst lst))
        (if (null? lst)
            (syntax-violation (and (pair? form) (car form)) "invalid syntax" form)
            (let ((clause (car lst)))
              (let ((pat (car clause))
                    (fender (cadr clause))
                    (expr (caddr clause)))
                (let ((vars (match form pat)))
                  (if (and vars
                           (or (not fender)
                               (fender (append vars patvars))))
                      (expr (append vars patvars))
                      (loop (cdr lst)))))))))))

(set-top-level-value! '.syntax-transcribe
  (lambda (vars template ranks identifier-lexname lexname-check-list)

    (define emit
      (lambda (datum)
        (cond ((wrapped-syntax-object? datum) datum)
              (else (make-syntax-object datum '() #f)))))

    (define partial-wrap-syntax-object
      (lambda (lst renames)
        (let loop ((lst lst))
          (cond ((contain-wrapped-syntax-object? lst)
                 (cond ((pair? lst)
                        (let ((a (loop (car lst))) (d (loop (cdr lst))))
                          (cond ((and (eq? (car lst) a) (eq? (cdr lst) d)) lst)
                                (else (cons a d)))))
                       (else lst)))
                ((symbol? lst)
                 (make-syntax-object lst (or (assq lst renames) '()) #f))
                ((or (pair? lst) (vector? lst))
                 (make-syntax-object lst renames #f))
                ((null? lst) '())
                (else
                 (make-syntax-object lst '() #f))))))

    (let* ((env-def
            (current-transformer-environment))
           (suffix
            (current-rename-count))
           (aliases
            (map (lambda (id) (cons id (rename-id id suffix)))
                 (collect-rename-ids template ranks)))
           (renames
            (map (lambda (lst) (cons (cdr lst) (env-lookup env-def (car lst))))
                 aliases))
           (out-of-context
            (cond ((null? lexname-check-list) '())
                  ((null? env-def) '())
                  (else
                   (filter values
                           (map (lambda (a)
                                  (let ((id (car a)))
                                    (cond ((assq id lexname-check-list)
                                           => (lambda (e)
                                                (cond ((eq? (lookup-lexical-name id env-def) (cdr e)) #f)
                                                      (else (cons (cdr a) (make-out-of-context template))))))
                                          (else #f))))
                                aliases))))))
      (let ((form (transcribe-template template ranks vars aliases emit)))
        (cond ((null? form) '())
              ((symbol? form)
               (make-syntax-object form (or (assq form out-of-context) (assq form renames) '()) identifier-lexname))
              ((wrapped-syntax-object? form)
               (if (null? (syntax-object-expr form)) '() form))
              (else
               (partial-wrap-syntax-object form (extend-env out-of-context renames))))))))

(define expand-syntax-case
  (lambda (form env)

    (define rewrite
      (lambda (form aliases)
        (let loop ((lst form))
          (cond ((pair? lst) (cons (loop (car lst)) (loop (cdr lst))))
                ((and (symbol? lst) (assq lst aliases)) => cdr)
                ((vector? lst) (list->vector (map loop (vector->list lst))))
                (else lst)))))

    (destructuring-match form
      ((_ expr lites clauses ...)
       (let ((lites (unrename-syntax lites env)))

         (or (and (list? lites) (every1 symbol? lites))
             (syntax-violation 'syntax-case "invalid literals" form lites))
         (or (unique-id-list? lites)
             (syntax-violation 'syntax-case "duplicate literals" form lites))
         (and (memq '_ lites)
              (syntax-violation 'syntax-case "_ in literals" form lites))
         (and (memq '... lites)
              (syntax-violation 'syntax-case "... in literals" form lites))

         (let ((renames (map (lambda (id) (cons id (lookup-lexical-name id env))) lites)))
           (let ((lites (rewrite lites renames)))

             (define parse-pattern
               (lambda (lst)
                 (let ((pattern (rewrite (unrename-syntax lst env) renames)))
                   (annotate pattern lst)
                   (check-pattern pattern lites)
                   (values pattern
                           (extend-env (map (lambda (a)
                                              (cons (car a)
                                                    (make-pattern-variable (cdr a))))
                                            (collect-vars-ranks pattern lites 0 '()))
                                       env)))))

             (annotate `(.syntax-dispatch
                         ,(expand-form '.patvars env)
                         ,(expand-form expr env)
                         ',lites
                         ,@(map (lambda (clause)
                                  (destructuring-match clause
                                    ((p expr)
                                     (let-values (((pattern env) (parse-pattern p)))
                                       `(.list ',pattern
                                               #f
                                               ,(expand-form `(.LAMBDA (.patvars) ,expr) env))))
                                    ((p fender expr)
                                     (let-values (((pattern env) (parse-pattern p)))
                                       `(.list ',pattern
                                               ,(expand-form `(.LAMBDA (.patvars) ,fender) env)
                                               ,(expand-form `(.LAMBDA (.patvars) ,expr) env))))))
                                clauses))
                       expr)))))
      (_
       (syntax-violation 'syntax-case "invalid syntax" form)))))

(define expand-syntax
  (lambda (form env)

    (define rewrite
      (lambda (form aliases)
        (let loop ((lst form))
          (cond ((pair? lst) (cons (loop (car lst)) (loop (cdr lst))))
                ((and (symbol? lst) (assq lst aliases)) => cdr)
                ((vector? lst) (list->vector (map loop (vector->list lst))))
                (else lst)))))

    (destructuring-match form
      ((_ tmpl)
       (let ((template (unrename-syntax tmpl env)))
         (let ((ids (collect-unique-ids template)))
           (let ((ranks
                  (filter values
                          (map (lambda (id)
                                 (let ((deno (env-lookup env id)))
                                   (and (pattern-variable? deno)
                                        (cons id (cdr deno)))))
                               ids))))
             (let ((lexname-check-list
                    (filter values
                            (map (lambda (id)
                                   (let ((lexname (lookup-lexical-name id env)))
                                     (and (renamed-id? lexname)
                                          (cond ((eq? id lexname) #f)
                                                (else (cons id lexname))))))
                                 (collect-rename-ids template ranks)))))
               (check-template template ranks)
               (let ((identifier-lexname (and (symbol? tmpl) (lookup-lexical-name tmpl env))))
                 (annotate `(.syntax-transcribe ,(expand-form '.patvars env) ',template ',ranks ',identifier-lexname ',lexname-check-list) form)))))))
      (_
       (syntax-violation 'syntax "expected exactly one datum" form)))))

(define syntax->datum
  (lambda (expr)
    (strip-rename-suffix
     (let loop ((lst expr))
       (cond ((pair? lst)
              (let ((a (loop (car lst))) (d (loop (cdr lst))))
                (cond ((and (eq? a (car lst)) (eq? d (cdr lst))) lst)
                      (else (cons a d)))))
             ((vector? lst)
              (list->vector (map loop (vector->list lst))))
             ((wrapped-syntax-object? lst)
              (loop (syntax-object-expr lst)))
             (else lst))))))

(define datum->syntax
  (lambda (template-id datum)
    (or (identifier? template-id)
        (assertion-violation 'datum->syntax (format "expected identifier, but got ~r" template-id)))
    (let ((suffix (retrieve-rename-suffix (syntax-object-expr template-id)))
          (env (if (null? (syntax-object-renames template-id))
                   (current-expansion-environment)
                   (current-transformer-environment)))
          (ht1 (make-core-hashtable))
          (ht2 (make-core-hashtable)))
      (let ((obj (let loop ((lst datum))
                   (cond ((pair? lst)
                          (cons (loop (car lst)) (loop (cdr lst))))
                         ((vector? lst)
                          (list->vector (map loop (vector->list lst))))
                         ((symbol? lst)
                          (cond ((core-hashtable-ref ht1 lst #f))
                                (else
                                 (let ((new (string->symbol (string-append (symbol->string lst) suffix))))
                                   (core-hashtable-set! ht1 lst new)
                                   (let ((deno-trans (env-lookup env new)))
                                     (cond ((eq? deno-trans new)
                                            ;; maybe capture expansion environment
                                            (core-hashtable-set! ht2 new (env-lookup env lst)))
                                           (else
                                            ;; maybe capture transformer environment
                                            (core-hashtable-set! ht2 new deno-trans))))
                                   new))))
                         (else lst)))))
        (if (symbol? obj)
            (make-syntax-object obj (or (assq obj (core-hashtable->alist ht2)) '()) #f)
            (make-syntax-object obj (core-hashtable->alist ht2) #f))))))

(define identifier?
  (lambda (datum)
    (and (wrapped-syntax-object? datum)
         (symbol? (syntax-object-expr datum)))))

(define bound-identifier=?
  (lambda (id1 id2)
    (or (identifier? id1)
        (assertion-violation 'bound-identifier=? (format "expected identifier, but got ~r" id1)))
    (or (identifier? id2)
        (assertion-violation 'bound-identifier=? (format "expected identifier, but got ~r" id2)))
    (eq? (syntax-object-expr id1) (syntax-object-expr id2))))

(define free-identifier=?
  (lambda (id1 id2)
    (or (identifier? id1)
        (assertion-violation 'free-identifier=? (format "expected identifier, but got ~r" id1)))
    (or (identifier? id2)
        (assertion-violation 'free-identifier=? (format "expected identifier, but got ~r" id2)))
    (let ((env (current-expansion-environment)))
      (let ((n1a (syntax-object-lexname id1))
            (n2a (syntax-object-lexname id2))
            (n1b (lookup-lexical-name (syntax-object-expr id1) env))
            (n2b (lookup-lexical-name (syntax-object-expr id2) env)))
        (if (and n1a n2a)
            (eq? n1a n2a)
            (or (eq? n1b n2b)
                (eq? n1a n2b)
                (eq? n1b n2a)))))))

(define generate-temporaries
  (lambda (obj)
    (or (list? obj)
        (assertion-violation 'generate-temporaries (format "expected list, but got ~r" obj)))
    (map (lambda (n) (make-syntax-object (generate-temporary-symbol) '() #f)) obj)))

(define make-variable-transformer
  (lambda (proc)
    (make-variable-transformer-token
     (lambda (x)
       (proc (if (wrapped-syntax-object? x)
                 x
                 (make-syntax-object x '() #f)))))))

(define make-variable-transformer-token
  (lambda (datum)
    (tuple 'type:variable-transformer-token datum)))

(define variable-transformer-token?
  (lambda (obj)
    (eq? (tuple-ref obj 0) 'type:variable-transformer-token)))

(set-top-level-value! '.transformer-thunk
  (lambda (code)
    (let ((thunk (lambda (x)
                   (call-with-values
                    (lambda () (code x))
                    (lambda (obj . env)
                      (if (null? env)
                          (.flatten-syntax obj)
                          (values obj (car env))))))))
      (cond ((procedure? code)
             (let-values (((nargs opt) (closure-arity code)))
               (and (= nargs 1) (= opt 0) thunk)))
            ((variable-transformer-token? code)
             (set! code (tuple-ref code 1))
             (make-variable-transformer-token thunk))
            (else code)))))
