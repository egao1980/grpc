;;;; -*- Mode: LISP; Syntax: Ansi-Common-Lisp; Base: 10; -*-

#.(unless (or #+asdf3.1 (version<= "3.1" (asdf-version)))
    (error "You need ASDF >= 3.1 to load this system correctly."))

(defsystem :grpc
  :author "Jonathan Godbout <jgodbout@google.com>"
  :version (:read-file-form "version.sexp")
  :description "Lisp wrapper for gRPC"
  :license "MIT"
  :defsystem-depends-on ("asdf-native")
  :depends-on ((:version :cl-protobufs "2.0.1") :cffi :bordeaux-threads)
  ;; Overlays: lib/<os>-<arch>/ per platform, from the :native-library component.
  ;; publish-oci.yml fills it with grpc.so plus the gRPC runtime that
  ;; scripts/bundle-grpc-native-deps.sh bundles next to it.
  :properties (:cl-repo (:provides ("grpc")))
  :serial t
  :in-order-to ((test-op (test-op :grpc/tests)))
  :components ((:file "grpc")
               ;; $GRPC_NATIVE, native/ (overlay), lib/<os>-<arch>/ (bundled
               ;; checkout build), then the system root (a plain `make`).
               (:native-library "grpc-wrapper"
                :names (:darwin ("grpc.dylib") :unix ("grpc.so"))
                :env "GRPC_NATIVE"
                :fallback-directories (""))
               (:file "shared")
               (:file "client")
               (:file "server")
               (:file "protobuf-integration")))

(defsystem :grpc/tests
  :name "Protobufs Tests"
  :author "Jonathan Godbout"
  :version "0.1"
  :licence "MIT-style"
  :maintainer '("Jon Godbout" "Carl Gay" "Nick Groszewski")
  :description      "Test code for gRPC for Common Lisp"
  :long-description "Test code for gRPC for Common Lisp"
  :defsystem-depends-on (:cl-protobufs.asdf)
  :depends-on (:grpc :clunit2 :flexi-streams :bordeaux-threads)
  :serial t
  :pathname "tests/"
  :components
  ((:module "packages"
    :serial t
    :pathname ""
    :components ((:file "pkgdcl")))
   (:module "root-suite"
    :serial t
    :pathname ""
    :components ((:file "root-suite")))
   (:module "integration-test"
    :serial t
    :pathname ""
    :depends-on ("packages")
    :components ((:file "integration-test")))
   (:module "cl-protobuf-integration-test"
    :serial t
    :pathname ""
    :depends-on ("packages")
    :components ((:protobuf-source-file "test")
                 (:file "cl-protobuf-integration-test"))))
  :perform (test-op (o c)
                    (uiop:symbol-call '#:grpc.test '#:run-all)))
