{
    "targets": [
        {
            "target_name": "nobjc_native",
            "sources": [
                "src/native/nobjc.mm",
                "src/native/ObjcObject.mm",
                "src/native/protocol-impl.mm"
            ],
            "defines": [
                "NODE_ADDON_API_CPP_EXCEPTIONS"
            ],
            "include_dirs": [
                "<!@(node -p \"require('node-addon-api').include\")"
            ],
            "dependencies": [
                "<!(node -p \"require('node-addon-api').gyp\")"
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