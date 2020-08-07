# Kernel

## Updating kernel config

When updating kernel to the new version, import proper defaults with:

```sh
make kernel-olddefconfig USERNAME=rsmitty
```

If you want to update for a specific architecture only, use:

```sh
make kernel-olddefconfig USERNAME=rsmitty PLATFORM=linux/arm64
```

## Customizing the kernel

Run another target to get into `menuconfig`:

```sh
make kernel-menuconfig USERNAME=rsmitty
```

## Testing

- Build and push a test image with `make USERNAME=rsmitty PUSH=true kernel`
- PR upstream (when ready) and profit
