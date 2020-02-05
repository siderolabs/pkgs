# Kernel

## Customizing the kernel

High-level notes:

- In pkg.yaml, comment out the `build` and `install` steps
- At the bottom of pkg.yaml, change the finalize step from

```yaml
finalize:
  - from: /rootfs
    to: /
```

to

```yaml
finalize:
  - from: /
    to: /
```

- Create a local image with `docker buildx build -t kernel --target kernel -f Pkgfile --load .`
- Run the kernel image we created: `docker run --rm -it --entrypoint=/toolchain/bin/bash kernel`
- Set path: `export PATH=/toolchain/bin:/bin`
- Change to build dir: `cd /tmp/build/0`
- Make changes to kernel settings with `make menuconfig` and save upon exiting
- With the container still running, copy the config out to local disk: `docker cp $CONTAINER_ID:/tmp/build/0/.config config-amd64`
- Revert your changes to pkg.yaml
- Build and push a test image with `make USERNAME=rsmitty PUSH=true kernel`
- PR upstream (when ready) and profit
