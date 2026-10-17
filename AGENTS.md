This is the project for a modern multiplatform hypercad.
It uses:
* sqllite for the stacks (documents)
* SwitfUI for Mac and iOS
* GPUI for Mac/Windows/Linux
* Work is tested on Mac with SwiftUI and Mac with GPUI (currently we do not yet test for other platform)
* Nothing must be installed on internal drive when developping or building because it is near full. One could install rust in /Volumes/Ext/Rust for gpui
* backend must work with GPUI and SwiftUI so will be in C++
* No GPL code must be used
* If code is imported from outside (when it cannot be avoided), copyright and licence should be preserved
* This work will be licensed with Apache license so any imported code must have a compatible licence
* GPUI build must be portable and work on Mac / Linux (and in future Windows)
* SwiftUI build can use standard swift build mechanism
* The root README.md will explain what the application is doing (summary of major features) and quick overview of the architecture. Details about the architectures and the features will be in the folder documentation and be linked from the root README.md The folder documentation is used during the project to document each new feature or new architecture development so that we keep a trace and can enforce some principles to be respected through the development