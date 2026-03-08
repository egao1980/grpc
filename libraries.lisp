;;; Copyright 2021 Google LLC
;;;
;;; Use of this source code is governed by an MIT-style
;;; license that can be found in the LICENSE file or at
;;; https://opensource.org/licenses/MIT.

;;;; Load foreign libraries.

(in-package #:grpc)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (cffi:define-foreign-library grpc-client-wrapper
    ;; Bare name first: cl-repo installs push native/ into cffi:*foreign-library-directories*
    ;; Absolute path fallback: development workflow (lib next to .asd file)
    (:darwin (:or "grpc.dylib"
                  #.(namestring (asdf:system-relative-pathname "grpc" "grpc.dylib"))))
    (t (:or (:default "grpc")
            (:default #.(namestring
                         (asdf:system-relative-pathname "grpc" "grpc"))))))
  (cffi:load-foreign-library 'grpc-client-wrapper))
