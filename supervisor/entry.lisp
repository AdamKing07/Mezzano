;;;; Copyright (c) 2011-2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.supervisor)

;;; FIXME: Should not be here.
;;; >>>>>>

(defstruct (stack
             (:constructor %make-stack (base size))
             (:area :wired))
  base
  size)

(defun %allocate-stack-1 (aligned-size bump-sym)
  (safe-without-interrupts (aligned-size bump-sym)
    (with-symbol-spinlock (mezzano.runtime::*wired-allocator-lock*)
      (prog1 (logior (+ (symbol-value bump-sym) #x200000) ; + 2MB for guard page
                     (ash sys.int::+address-tag-stack+ sys.int::+address-tag-shift+))
        (incf (symbol-value bump-sym) aligned-size)))))

;; TODO: Actually allocate virtual memory.
(defun %allocate-stack (size &optional wired)
  (declare (sys.c::closure-allocation :wired))
  ;; 4k align the size.
  (setf size (logand (+ size #xFFF) (lognot #xFFF)))
  ;; 2m align the memory region.
  (let* ((addr (%allocate-stack-1 (align-up size #x200000)
                                  (if wired
                                      'sys.int::*wired-stack-area-bump*
                                      'sys.int::*stack-area-bump*)))
         (stack (%make-stack addr size)))
    ;; Allocate blocks.
    (loop
       for i from 0 do
         (when (allocate-memory-range addr size
                                      (logior sys.int::+block-map-present+
                                              sys.int::+block-map-writable+
                                              sys.int::+block-map-zero-fill+))
           (return))
         (when (> i mezzano.runtime::*maximum-allocation-attempts*)
           (error 'storage-condition))
         (debug-print-line "No memory for stack, calling GC.")
         (sys.int::gc))
    (sys.int::make-weak-pointer stack stack
                                (lambda ()
                                  (release-memory-range addr size))
                                :wired)
    stack))

(defun reboot ()
  ;; FIXME: Need to sync disks and wait until snapshotting finishes.
  ;; TODO: ACPI rebooting.
  ;; Attempt one: pulse the reset line via the PS/2 controller.
  (ps/2-input-wait)
  (setf (system:io-port/8 +ps/2-control-port+) #xFE) ; Pulse output line 0 low.
  ;; Attempt two: trash the IDT and trigger a page-fault to triple-fault the CPU.
  (%lidt 0 0)
  (sys.int::memref-unsigned-byte-8 0 0)
  nil)

;;; <<<<<<

(sys.int::defglobal *boot-information-page*)

(defconstant +virtual-address-bits+ 48)
(defconstant +log2-4k-page+ 12)
(defconstant +n-32-bit-physical-buddy-bins+ (- 32 +log2-4k-page+)
  "Number of buddy bins for the below 4GB allocator.")
(defconstant +n-64-bit-physical-buddy-bins+ (- 39 +log2-4k-page+)
  "Number of buddy bins for the above 4GB allocator.")

(defconstant +buddy-bin-size+ 16
  "Size in bytes of one buddy bin.")

(defconstant +boot-information-boot-uuid-offset+                  0)
(defconstant +boot-information-32-bit-physical-buddy-bins-offset+ 16)
(defconstant +boot-information-64-bit-physical-buddy-bins-offset+ 336)
(defconstant +boot-information-video+                             768)
(defconstant +boot-information-framebuffer-physical-address+      (+ +boot-information-video+ 0))
(defconstant +boot-information-framebuffer-width+                 (+ +boot-information-video+ 8))
(defconstant +boot-information-framebuffer-pitch+                 (+ +boot-information-video+ 16))
(defconstant +boot-information-framebuffer-height+                (+ +boot-information-video+ 24))
(defconstant +boot-information-framebuffer-layout+                (+ +boot-information-video+ 32))
(defconstant +boot-information-acpi-rsdp+                         808)
(defconstant +boot-information-options+                           816)
(defconstant +boot-information-n-memory-map-entries+              824)
(defconstant +boot-information-memory-map+                        832)
(defconstant +boot-information-efi-system-table+                 1344)

(defconstant +boot-option-force-read-only+ #x01)

(defun boot-uuid (offset)
  (check-type offset (integer 0 15))
  (sys.int::memref-unsigned-byte-8 (+ +boot-information-boot-uuid-offset+ *boot-information-page*)
                                   offset))

(sys.int::defglobal *boot-hook-lock*)
(sys.int::defglobal *boot-hooks*)
(sys.int::defglobal *late-boot-hooks*)

(defun add-boot-hook (fn &optional when)
  (check-type when (member nil :late))
  (with-mutex (*boot-hook-lock*)
    (case when
      ((nil)
       (push fn *boot-hooks*))
      (:late
       (push fn *late-boot-hooks*)))))

(defun remove-boot-hook (fn)
  (with-mutex (*boot-hook-lock*)
    (setf *boot-hooks* (remove fn *boot-hooks*))
    (setf *late-boot-hooks* (remove fn *late-boot-hooks*))))

(defun run-boot-hooks ()
  (dolist (hook *boot-hooks*)
    (sys.int::log-and-ignore-errors
      (format t "Run boot hook ~A~%" hook)
      (funcall hook)))
  (dolist (hook *late-boot-hooks*)
    (sys.int::log-and-ignore-errors
      (format t "Run late boot hook ~A~%" hook)
      (funcall hook))))

(sys.int::defglobal *boot-id*)

(defstruct (nic
             (:area :wired))
  device
  mac
  transmit-packet
  stats
  mtu)

(sys.int::defglobal *nics*)
(sys.int::defglobal *received-packets*)

(defun register-nic (device mac transmit-fn stats-fn mtu)
  (debug-print-line "Registered NIC " device " with MAC " mac)
  (push-wired (make-nic :device device
                        :mac mac
                        :transmit-packet transmit-fn
                        :stats stats-fn
                        :mtu mtu)
              *nics*))

(defun net-statistics (nic)
  "Get NIC statistics. Returns 7 values:
Bytes received.
Packets received.
Receive errors.
Bytes transmitted.
Packets transmitted.
Transmit errors.
Collisions."
  (funcall (nic-stats nic) (mezzano.supervisor::nic-device nic)))

(defun net-transmit-packet (nic pkt)
  (set-network-light t)
  (set-network-light nil)
  (funcall (mezzano.supervisor::nic-transmit-packet nic)
           (mezzano.supervisor::nic-device nic)
           pkt))

(defun net-receive-packet ()
  "Wait for a packet to arrive.
Returns two values, the packet data and the receiving NIC."
  (set-network-light t)
  (set-network-light nil)
  (let ((info (irq-fifo-pop *received-packets*)))
    (values (cdr info) (car info))))

(defun nic-received-packet (device pkt)
  (let ((nic (find device *nics* :key #'nic-device)))
    (when nic
      (irq-fifo-push (cons nic pkt) *received-packets*))))

(defun initialize-net ()
  (when (not (boundp '*received-packets*))
    ;; First run.
    ;; FIXME: This should be a normal non-IRQ FIFO, but
    ;; creating a FIFO won't work until the cold load finishes.
    (setf *received-packets* (make-irq-fifo 50)))
  (setf *nics* '())
  (irq-fifo-reset *received-packets*))

(sys.int::defglobal *deferred-boot-actions*)

(defun add-deferred-boot-action (action)
  (if (boundp '*deferred-boot-actions*)
      (push-wired action *deferred-boot-actions*)
      (funcall action)))

(sys.int::defglobal *post-boot-worker-thread*)

(defun post-boot-worker ()
  (loop
     ;; Run deferred boot actions first.
     (dolist (action *deferred-boot-actions*)
       (funcall action))
     (makunbound '*deferred-boot-actions*)
     ;; Now normal boot hooks.
     (run-boot-hooks)
     ;; Sleep til next boot.
     (%run-on-wired-stack-without-interrupts (sp fp)
      (let ((self (current-thread)))
        (decf *snapshot-inhibit*)
        (setf (thread-wait-item self) "Next boot"
              (thread-state self) :sleeping)
        (%reschedule-via-wired-stack sp fp)))))

(defun sys.int::bootloader-entry-point (boot-information-page)
  (let ((first-run-p nil))
    (initialize-boot-cpu)
    (initialize-debug-log)
    (initialize-platform-early-console boot-information-page)
    (initialize-initial-thread)
    (setf *boot-information-page* boot-information-page
          *cold-unread-char* nil
          mezzano.runtime::*paranoid-allocation* nil
          *deferred-boot-actions* '()
          *paging-disk* nil
          *page-fault-hook* nil)
    (initialize-physical-allocator)
    (initialize-early-video)
    (when (not (boundp 'mezzano.runtime::*active-catch-handlers*))
      (setf first-run-p t)
      (mezzano.runtime::first-run-initialize-allocator)
      ;; FIXME: Should be done by cold generator
      (setf mezzano.runtime::*active-catch-handlers* 'nil
            *pseudo-atomic* nil
            sys.int::*known-finalizers* nil))
    (setf *boot-id* (sys.int::cons-in-area nil nil :wired))
    (initialize-early-platform)
    (initialize-threads)
    (initialize-disk)
    (initialize-pager)
    (initialize-snapshot)
    (%enable-interrupts)
    ;;(debug-set-output-pseudostream #'debug-video-stream)
    ;;(debug-set-output-pseudostream (lambda (op &optional arg) (declare (ignore op arg))))
    (debug-write-line "Hello, Debug World!")
    (initialize-time)
    (initialize-net)
    (initialize-ata)
    (initialize-video)
    (initialize-efi)
    (initialize-acpi)
    (initialize-platform)
    (detect-disk-partitions)
    (detect-paging-disk)
    (when (not *paging-disk*)
      (panic "Could not find boot device. Sorry."))
    (cond (first-run-p
           (setf *post-boot-worker-thread* (make-thread #'post-boot-worker :name "Post-boot worker thread")
                 *boot-hook-lock* (make-mutex "Boot Hook Lock")
                 *boot-hooks* '()
                 *late-boot-hooks* '())
           (make-thread #'sys.int::initialize-lisp :name "Main thread"))
          (t (wake-thread *post-boot-worker-thread*)))
    (finish-initial-thread)))
