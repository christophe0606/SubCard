This is the project for a modern multiplatform hypercad.
It uses:
* sqllite for the stacks (documents)
* SwitfUI for Mac and iOS
* GPUI for Mac/Windows/Linux
* Work is tested on Mac with SwiftUI and Mac with GPUI (currently we do not yet test for other platform)
* Nothing must be installed on internal drive when developping or building because it is near full. One could install rust in /Volumes/Ext/Rust for gpui
* Do not install or run iPhone/iOS simulators or simulator runtimes. The internal drive is too full, and simulator installation on the external drive is not an option for this project. Validate iPhone changes by compiling for a physical iPhone; perform device testing only when an authorized physical device is available.
* backend must work with GPUI and SwiftUI so will be in C++
* No GPL code must be used
* If code is imported from outside (when it cannot be avoided), copyright and licence should be preserved
* This work will be licensed with Apache license so any imported code must have a compatible licence
* GPUI build must be portable and work on Mac / Linux (and in future Windows)
* SwiftUI build can use standard swift build mechanism
* The root README.md will explain what the application is doing (summary of major features) and quick overview of the architecture. Details about the architectures and the features will be in the folder documentation and be linked from the root README.md The folder documentation is used during the project to document each new feature or new architecture development so that we keep a trace and can enforce some principles to be respected through the development
* Don't use any private key, password in the files that are published
* After testing apps with computer use, quit every app instance launched for testing, including temporary test builds and alternate versions, so they do not accumulate. Preserve any pre-existing user app instances and unsaved work.
* Follow each platform's native interaction patterns; desktop and iPhone must not share an identical command layout merely for implementation convenience.
* On desktop, standard document and editing commands (New/Open/Close/Save/Save As, Undo/Redo, Cut/Copy/Paste, Duplicate/Delete, etc.) belong in the global application menus with standard shortcuts and context-sensitive enabled states. Do not duplicate them as buttons above the canvas or in the inspector. Keep the canvas toolbar for canvas-specific tools such as adding tables/relationships and zooming. Text inputs must retain their normal text-editing commands.
* On desktop, show document identity and unsaved state through the window title, native edited-window indicator, and Save menu availability; do not add a duplicate document title or Saved/Edited banner above the canvas.
* Desktop document windows own independent document/editor state. Global menu commands, shortcuts, validation, Save, and Close must target the focused document window; text-editing commands target its active text input. Never use a shared singleton document or whichever window happened to be created first. Quitting must protect unsaved changes in every open document window.
* On iPhone, use native navigation/document controls and a compact toolbar command menu where global desktop menus are unavailable. Preserve the canvas with a single table tap; use a double tap to open table details. Document and validate desktop and iPhone presentation separately when introducing commands or navigation.
