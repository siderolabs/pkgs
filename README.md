# pkgs

![Dependency Diagram](/deps.png)

This repository produces a set of packages that can be used to build a rootfs suitable for creating custom Linux distributions.
The packages are published as a container image, and can be "installed" by simply copying the contents to your rootfs.
For example, using Docker, we can do the following:

```docker
FROM scratch
COPY --from=<registry>/<organization>/<pkg>:<tag> / /
```

## Resources

- https://gcc.gnu.org/onlinedocs/gccint/Configure-Terms.html
- https://wiki.osdev.org/Target_Triplet
