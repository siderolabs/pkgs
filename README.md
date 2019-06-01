# pkgs

This repository produces a set of packages that can be used to build a rootfs suitable for creating custom Linux distributions.
The builds use a base container that has been built using a toolchain that creates binaries with a search path of `/toolchain/lib`.
The toolchain has been adjusted to produce binaries with standard search paths.

## Resources

- https://gcc.gnu.org/onlinedocs/gccint/Configure-Terms.html
- https://wiki.osdev.org/Target_Triplet
