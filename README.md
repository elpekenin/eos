Elpekenin's Operating System (eos for short)

This is just an playground to learn about zig and operating system

Eventual goal is to have a file-system, where some binaries are stored, and execute them using an userland shell that reads keyboard input (probably bare GPIO reading of buttons, no USB or anything).

Other ideas:
* Custom dynamic loader + shared library for syscalls and whatnot
* Writable file-system
* Compile code within the OS (a toy language?)
