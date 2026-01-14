{
    "targets": [
        {
            "target_name": "nobjc_native",
            "sources": [
                "src/native/nobjc.mm",
                "src/native/ObjcObject.mm",
                "src/native/protocol-impl.mm",
                "src/native/method-forwarding.mm",
                "src/native/subclass-impl.mm",
                "src/native/forwarding-common.mm"
            ],
            "defines": [
                "NODE_ADDON_API_CPP_EXCEPTIONS",
                "NAPI_VERSION=6"
            ],
            "include_dirs": [
                "<!@(node -p \"require('node-addon-api').include\")",
                "<!@(brew --prefix libffi)/include"
            ],
            "dependencies": [
                "<!(node -p \"require('node-addon-api').gyp\")"
            ],
            "libraries": [
                "<!@(brew --prefix libffi)/lib/libffi.a"
            ],
            "xcode_settings": {
                "MACOSX_DEPLOYMENT_TARGET": "13.3",
                "CLANG_CXX_LIBRARY": "libc++",
                "OTHER_CPLUSPLUSFLAGS": [
                    "-std=c++20",
                    "-fexceptions"
                ],
                "OTHER_CFLAGS": [
                    "-fobjc-arc"
                ]
            }
        }
    ]
}