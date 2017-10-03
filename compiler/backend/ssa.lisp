;;;; Copyright (c) 2017 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;; SSA-related functions.

(in-package :mezzano.compiler.backend)

(defun check-definitions-dominate-uses (backend-function)
  "Check that all virtual-register uses are dominated by their definitions.
This only works on functions in SSA form."
  (let ((dom (mezzano.compiler.backend.dominance:compute-dominance backend-function)))
    (labels ((check-defs-dominate-uses (def-stack bb)
               (do ((inst bb (next-instruction backend-function inst)))
                   ((null inst))
                 (dolist (input (instruction-inputs inst))
                   (when (typep input 'virtual-register)
                     (assert (member input def-stack) (inst def-stack)
                             "Instruction ~S uses ~S before definition."
                             inst input)))
                 (dolist (output (instruction-outputs inst))
                   (when (typep output 'virtual-register)
                     (push output def-stack)))
                 (when (typep inst 'terminator-instruction)
                   (return)))
               (dolist (child (mezzano.compiler.backend.dominance:dominator-tree-children dom bb))
                 (check-defs-dominate-uses def-stack child))))
      (check-defs-dominate-uses '() (first-instruction backend-function)))))

(defun check-ssa (backend-function)
  "Verify that BACKEND-FUNCTION is in SSA form.
Virtual registers must be defined exactly once."
  (multiple-value-bind (uses defs)
      (build-use/def-maps backend-function)
    (declare (ignore uses))
    (maphash (lambda (def insts)
               (assert (not (endp insts)) (def)
                       "Virtual register ~S has no definitions?" def)
               (assert (endp (rest insts)) (def insts)
                       "Virtual register ~S defined by multiple instructions ~S"
                       def insts))
             defs))
  (check-definitions-dominate-uses backend-function))

(defun deconstruct-ssa (backend-function)
  "Deconstruct SSA form, replacing phi nodes with moves."
  (check-ssa backend-function)
  (sys.c:with-metering (:backend-deconstruct-ssa)
    (let ((n-moves-inserted 0)
          (n-phis-converted 0))
      (do-instructions (inst backend-function)
        (when (typep inst 'jump-instruction)
          ;; Phi nodes have parallel assignment semantics.
          ;; Try to reduce the number of moves inserted.
          ;; Before:
          ;;   jump foo (a c b x)
          ;;   label foo (a b c d)
          ;; After:
          ;;   move t1 b [temporaries generated for parallel assignment]
          ;;   move t2 c
          ;;   [move from a to a elided]
          ;;   move b t2
          ;;   move c t1
          ;;   move d x
          ;;   jump foo ()
          ;;   label foo ()
          (let* ((conflicts (loop
                               for phi in (label-phis (jump-target inst))
                               for value in (jump-values inst)
                               when (loop
                                       for other-phi in (label-phis (jump-target inst))
                                       when (and (not (eql phi other-phi))
                                                 (eql other-phi value))
                                       do (return t)
                                       finally (return nil))
                               collect phi))
                 (real-values (loop
                                 for value in (jump-values inst)
                                 collect (cond ((member value conflicts)
                                                (let ((new-reg (make-instance 'virtual-register)))
                                                  (incf n-moves-inserted)
                                                  (insert-before backend-function inst
                                                                 (make-instance 'move-instruction
                                                                                :source value
                                                                                :destination new-reg))
                                                  new-reg))
                                               (t
                                                value)))))
            (loop
               for phi in (label-phis (jump-target inst))
               for value in real-values
               do
                 (when (not (eql phi value))
                   (incf n-moves-inserted)
                   (insert-before backend-function inst
                                  (make-instance 'move-instruction
                                                 :source value
                                                 :destination phi))))
            (setf (jump-values inst) '()))))
      (do-instructions (inst backend-function)
        (when (typep inst 'label)
          (incf n-phis-converted (length (label-phis inst)))
          (setf (label-phis inst) '())))
      (when (not *shut-up*)
        (format t "Deconstructed ~D phi variables, inserted ~D moves.~%"
                n-phis-converted n-moves-inserted)))))

(defun test-deconstruct-function ()
  (let* ((x (make-instance 'virtual-register :name :x))
         (a (make-instance 'virtual-register :name :a))
         (b (make-instance 'virtual-register :name :b))
         (c (make-instance 'virtual-register :name :c))
         (d (make-instance 'virtual-register :name :d))
         (label (make-instance 'label :name :label :phis (list a b c d)))
         (fn (make-instance 'backend-function)))
    (append-instruction fn (make-instance 'argument-setup-instruction
                                          :fref (make-instance 'virtual-register)
                                          :count (make-instance 'virtual-register)
                                          :closure (make-instance 'virtual-register)
                                          :required (list x)
                                          :optional ()
                                          :rest nil))
    (append-instruction fn (make-instance 'jump-instruction
                                          :target label
                                          :values (list x x x x)))
    (append-instruction fn label)
    (append-instruction fn (make-instance 'jump-instruction
                                          :target label
                                          :values (list a c b x)))
    fn))

(defun discover-ssa-conversion-candidates (backend-function)
  (let ((simple-transforms '())
        (full-transforms '())
        (rejected-transforms '()))
    ;; Locals that are not stored into can be trivially converted by replacing
    ;; loads with the original binding.
    ;; Locals that are stored into must undergo the full SSA conversion
    ;; algorithm. Additionally, these locals will not be transformed if
    ;; they are live over an NLX region. Phi nodes are not permitted i
    ;; NLX thunks.
    (do-instructions (inst backend-function)
      (when (typep inst 'bind-local-instruction)
        (push inst simple-transforms))
      (when (and (typep inst 'store-local-instruction)
                 (member (store-local-local inst) simple-transforms))
        (setf simple-transforms (remove (store-local-local inst)
                                        simple-transforms))
        (push (store-local-local inst) full-transforms)))
    (when (not (endp full-transforms))
      ;; Build dynamic contours and eliminate variables live during NLX regions.
      (let ((contours (dynamic-contours backend-function)))
        (do-instructions (inst backend-function)
          (when (typep inst 'begin-nlx-instruction)
            (let ((reject (intersection (gethash inst contours)
                                        full-transforms)))
              (setf rejected-transforms (append reject rejected-transforms)))
            (setf full-transforms (set-difference full-transforms (gethash inst contours)))))))
    (values simple-transforms
            full-transforms
            rejected-transforms)))

(defun ssa-convert-simple-locals (backend-function candidates)
  "Each candidate has one definition. All loads are replaced with the bound value."
  (let ((remove-me '())
        (n-simple-loads-converted 0))
    (multiple-value-bind (uses defs)
        (build-use/def-maps backend-function)
      (declare (ignore defs))
      (do-instructions (inst backend-function)
        (when (and (typep inst 'load-local-instruction)
                   (member (load-local-local inst) candidates))
          (dolist (u (gethash (load-local-destination inst) uses))
            (replace-all-registers u
                                   (lambda (reg)
                                     (cond ((eql reg (load-local-destination inst))
                                            (bind-local-value (load-local-local inst)))
                                           (t reg)))))
          (push inst remove-me)
          (incf n-simple-loads-converted))))
    (dolist (inst remove-me)
      (remove-instruction backend-function inst))
    (when (not *shut-up*)
      (format t "Converted ~D simple loads.~%" n-simple-loads-converted))
    n-simple-loads-converted))

(defun ssa-convert-one-local (backend-function candidate dom basic-blocks bb-preds bb-succs)
  (declare (ignore basic-blocks bb-succs))
  (let ((visited (make-hash-table))
        (phi-sites '())
        (def-sites '())
        (binding-bb nil))
    ;; Locate basic blocks containing the binding & stores.
    (do* ((inst (first-instruction backend-function)
                (next-instruction backend-function inst))
          (current-bb inst))
         ((null inst))
      (when (or (and (typep inst 'store-local-instruction)
                     (eql (store-local-local inst) candidate))
                (eql inst candidate))
        (when (eql inst candidate)
          (setf binding-bb current-bb))
        (when (not (gethash current-bb visited))
          (setf (gethash current-bb visited) t)
          (push current-bb def-sites)))
      (when (typep inst 'terminator-instruction)
        (setf current-bb (next-instruction backend-function inst))))
    (when (not *shut-up*)
      (format t "Def sites for ~S: ~:S~%" candidate def-sites))
    (loop
       (when (endp def-sites)
         (return))
       (dolist (frontier (mezzano.compiler.backend.dominance:dominance-frontier dom (pop def-sites)))
         (when (and (not (member frontier phi-sites))
                    ;; Only care about blocks dominated by the binding.
                    (mezzano.compiler.backend.dominance:dominatep dom binding-bb frontier))
           (push frontier phi-sites)
           (when (not (gethash frontier visited))
             (setf (gethash frontier visited) t)
             (push frontier def-sites)))))
    (when (not *shut-up*)
      (format t "Phi sites for ~S: ~:S~%" candidate phi-sites))
    ;; FIXME: Critical edges will prevent phi insertion, need to break them.
    ;; work around this by bailing out whenever a phi site's predecessor is
    ;; terminated by a non-jump.
    (dolist (bb phi-sites)
      ;; FIXME: basic blocks have a weird & stupid representation.
      (when (not (typep bb 'label))
        (when (not *shut-up*)
          (format t "Bailing out of conversion for ~S due to non-label phi-site ~S.~%"
                  candidate bb))
        (return-from ssa-convert-one-local nil))
      (dolist (pred (gethash bb bb-preds))
        (loop
           (when (typep pred 'terminator-instruction) (return))
           (setf pred (next-instruction backend-function pred)))
        (when (not (typep pred 'jump-instruction))
          (when (not *shut-up*)
            (format t "Bailing out of conversion for ~S due to non-jump ~S.~%"
                    candidate pred))
          (return-from ssa-convert-one-local nil))))
    ;; Insert phi nodes.
    (dolist (bb phi-sites)
      (let ((phi (make-instance 'virtual-register :name `(:phi ,candidate))))
        (push phi (label-phis bb))
        ;; Update each predecessor jump.
        (dolist (pred (gethash bb bb-preds))
          (loop
             (when (typep pred 'terminator-instruction) (return))
             (setf pred (next-instruction backend-function pred)))
          (let ((tmp (make-instance 'virtual-register)))
            (insert-before backend-function pred
                           (make-instance 'load-local-instruction
                                          :local candidate
                                          :destination tmp))
            (push tmp (jump-values pred))))
        ;; And insert stores after each phi.
        (insert-after backend-function bb
                      (make-instance 'store-local-instruction
                                     :local candidate
                                     :value phi))))
    ;; Now walk the dominator tree to rename values, starting at the binding's basic block.
    (let ((uses (build-use/def-maps backend-function)))
      (labels ((rename (bb stack)
                 (let ((inst bb))
                   (loop
                      (typecase inst
                        (load-local-instruction
                         (when (eql (load-local-local inst) candidate)
                           (let ((new-value (first stack))
                                 (load-value (load-local-destination inst)))
                             ;; Replace all uses with the new value
                             (dolist (u (gethash load-value uses))
                               (replace-all-registers u
                                                      (lambda (reg)
                                                        (cond ((eql reg load-value)
                                                               new-value)
                                                              (t reg))))))))
                        (store-local-instruction
                         (when (eql (store-local-local inst) candidate)
                           (push (store-local-value inst) stack))))
                      (when (typep inst 'terminator-instruction)
                        (return))
                      (setf inst (next-instruction backend-function inst))))
                 (dolist (child (mezzano.compiler.backend.dominance:dominator-tree-children dom bb))
                   (rename child stack))))
        (rename binding-bb
                ;; Initial value is whatever value it was bound with.
                (list (bind-local-value candidate)))))
    t))

(defun ssa-convert-locals (backend-function candidates)
  (multiple-value-bind (basic-blocks bb-preds bb-succs)
      (build-cfg backend-function)
    (let ((dom (mezzano.compiler.backend.dominance:compute-dominance backend-function))
          (n-converted 0)
          (converted '()))
      (dolist (candidate candidates)
        (when (ssa-convert-one-local backend-function candidate dom basic-blocks bb-preds bb-succs)
          (push candidate converted)
          (incf n-converted)))
      ;; Walk through and remove any load instructions associated with
      ;; converted bindings.
      (let ((remove-me '()))
        (do-instructions (inst backend-function)
          (when (and (typep inst 'load-local-instruction)
                     (member (load-local-local inst) converted))
            (push inst remove-me)))
        (dolist (inst remove-me)
          (remove-instruction backend-function inst)))
      n-converted)))

(defun construct-ssa (backend-function)
  "Convert locals to SSA registers."
  (sys.c:with-metering (:backend-construct-ssa)
    (multiple-value-bind (simple-transforms full-transforms rejected-transforms)
        (discover-ssa-conversion-candidates backend-function)
      (when (not *shut-up*)
        (format t "Directly converting ~:S~%" simple-transforms)
        (format t "Fully converting ~:S~%" full-transforms)
        (format t "Rejected converting ~:S~%" rejected-transforms))
      (when (not (endp simple-transforms))
        (ssa-convert-simple-locals backend-function simple-transforms))
      (when (not (endp full-transforms))
        (ssa-convert-locals backend-function full-transforms)))))