// SPDX-License-Identifier: GPL-2.0-only
//
// nvhost_ctrl_shim.c — nvhost-ctrl userspace API shim for Talos Linux / Jetson Orin NX
//
// Per-ioctl trace logging uses pr_debug — enable at runtime with:
//   echo "file nvhost_ctrl_shim.c +p" > /sys/kernel/debug/dynamic_debug/control
//
// Provides /dev/nvhost-ctrl with the NVHOST_IOCTL_CTRL_* interface,
// bridging to the OOT host1x syncpoint kernel API.
//
// This allows libnvrm_host1x.so (JetPack 6 CUDA runtime) to use hardware
// syncpoint interrupts for cudaStreamSynchronize — replacing the CPU semaphore
// busy-wait with interrupt-driven sync.
//
// Symbol dependencies (all from host1x.ko):
//   host1x_syncpt_get_by_id_noref, host1x_syncpt_read, host1x_syncpt_read_max,
//   host1x_fence_create, host1x_fence_extract
//
// Supported ioctls (from linux-nv-oot/include/uapi/linux/nvhost_ioctl.h):
//   NVHOST_IOCTL_CTRL_GET_VERSION          (7)  → return 1
//   NVHOST_IOCTL_CTRL_SYNCPT_READ          (1)  → host1x_syncpt_read()
//   NVHOST_IOCTL_CTRL_SYNCPT_READ_MAX      (8)  → host1x_syncpt_read_max()
//   NVHOST_IOCTL_CTRL_SYNCPT_WAITMEX       (9)  → dma_fence_wait_timeout() [interrupt-driven]
//   NVHOST_IOCTL_CTRL_SYNC_FENCE_CREATE    (11) → host1x_fence_create() → sync_file fd
//   NVHOST_IOCTL_CTRL_GET_CHARACTERISTICS  (14) → return Orin hw syncpt info
//   NVHOST_IOCTL_CTRL_POLL_FD_CREATE       (16) → anon_inode fd for syncpt event polling
//   NVHOST_IOCTL_CTRL_SYNC_FILE_EXTRACT    (19) → sync_file fd → host1x_fence_extract()
//
// Targets kernel 6.18 (Talos v1.12.6):
//   - class_create() without THIS_MODULE (kernel 6.4+)
//   - devnode() callback with const struct device * (kernel 6.2+)
//   - close_fd() (kernel 5.11+, replaces __close_fd)
//
// CUDA 12.6 (JetPack 6) call sequence:
//   1. open(/dev/nvhost-ctrl)
//   2. GET_CHARACTERISTICS (nr=14): discover num_syncpts=704 etc.
//   3. SYNCPT_WAITMEX (nr=9): blocking wait for syncpt id/thresh → interrupt-driven
//   4. POLL_FD_CREATE (nr=16): once at GPU scaling init — creates anonymous poll fd
//   Note: SYNC_FENCE_CREATE (nr=11) is NOT called by CUDA 12.6 directly but kept
//         for other potential callers (e.g. media codecs, test tools).

#include <linux/anon_inodes.h>
#include <linux/cdev.h>
#include <linux/delay.h>
#include <linux/dma-fence-array.h>
#include <linux/fdtable.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/host1x-next.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/poll.h>
#include <linux/slab.h>
#include <linux/sync_file.h>
#include <linux/uaccess.h>

// ── NVHOST uapi structs (from linux-nv-oot/include/uapi/linux/nvhost_ioctl.h) ──
// Embedded directly to avoid uapi header path issues in OOT build.

#define NVHOST_IOCTL_MAGIC 'H'

// nr=7: GET_VERSION
struct nvhost_get_param_args {
	__u32 value;
} __packed;

// nr=1,8: SYNCPT_READ / SYNCPT_READ_MAX
struct nvhost_ctrl_syncpt_read_args {
	__u32 id;
	__u32 value;
};

// nr=9: SYNCPT_WAITMEX — blocking wait until syncpt.value >= thresh
struct nvhost_ctrl_syncpt_waitmex_args {
	__u32 id;        /* syncpoint id (in) */
	__u32 thresh;    /* wait until value >= thresh (in) */
	__s32 timeout;   /* timeout in ms; -1 = wait forever (in) */
	__u32 value;     /* syncpt value after wait (out) */
	__u32 tv_sec;    /* timestamp seconds (out) */
	__u32 tv_nsec;   /* timestamp nanoseconds (out) */
	__u32 clock_id;  /* clock selector (in, ignored) */
	__u32 reserved;
};

// nr=10,11: SYNC_FENCE_CREATE (nr=10 is 32-bit compat, nr=11 is 64-bit)
struct nvhost_ctrl_sync_fence_info {
	__u32 id;
	__u32 thresh;
};

struct nvhost_ctrl_sync_fence_create_args {
	__u32 num_pts;
	__s32 fence_fd;
	__u64 pts;     /* struct nvhost_ctrl_sync_fence_info __user * */
	__u64 name;    /* const char __user * — ignored, fences are anonymous */
};

// nr=14: GET_CHARACTERISTICS — host1x capability discovery
struct nvhost_characteristics {
#define NVHOST_CHARACTERISTICS_GFILTER                    (1 << 0)
#define NVHOST_CHARACTERISTICS_RESOURCE_PER_CHANNEL_INSTANCE (1 << 1)
#define NVHOST_CHARACTERISTICS_SUPPORT_PREFENCES          (1 << 2)
	__u64 flags;
	__u32 num_mlocks;
	__u32 num_syncpts;
	__u32 syncpts_base;
	__u32 syncpts_limit;
	__u32 num_hw_pts;
	__u32 padding;
};

struct nvhost_ctrl_get_characteristics {
	__u64 nvhost_characteristics_buf_size;
	__u64 nvhost_characteristics_buf_addr;
};

// nr=16: POLL_FD_CREATE — creates an anonymous fd for syncpoint event polling.
// Called once by gk20a_scale_init during GPU frequency-scaling setup.
// The fd is used with poll()/epoll() to wait for syncpoint threshold events.
// Our implementation returns a real anonymous inode fd so callers get a valid
// file descriptor without ENOTTY; the fd is pollable (returns POLLHUP on close).
struct nvhost_ctrl_poll_fd_create_args {
	__s32 fd;      /* out: anonymous poll fd */
	__u32 padding;
};

// nr=19: SYNC_FILE_EXTRACT
struct nvhost_ctrl_sync_file_extract {
	__s32 fd;
	__u32 num_fences;
	__u64 fences_ptr; /* struct nvhost_ctrl_sync_fence_info __user * */
};

// ── Ioctl definitions ─────────────────────────────────────────────────────────

#define NVHOST_IOCTL_CTRL_SYNCPT_READ \
	_IOWR(NVHOST_IOCTL_MAGIC, 1, struct nvhost_ctrl_syncpt_read_args)
#define NVHOST_IOCTL_CTRL_GET_VERSION \
	_IOR(NVHOST_IOCTL_MAGIC, 7, struct nvhost_get_param_args)
#define NVHOST_IOCTL_CTRL_SYNCPT_READ_MAX \
	_IOWR(NVHOST_IOCTL_MAGIC, 8, struct nvhost_ctrl_syncpt_read_args)
#define NVHOST_IOCTL_CTRL_SYNCPT_WAITMEX \
	_IOWR(NVHOST_IOCTL_MAGIC, 9, struct nvhost_ctrl_syncpt_waitmex_args)
#define NVHOST_IOCTL_CTRL_SYNC_FENCE_CREATE \
	_IOWR(NVHOST_IOCTL_MAGIC, 11, struct nvhost_ctrl_sync_fence_create_args)
#define NVHOST_IOCTL_CTRL_GET_CHARACTERISTICS \
	_IOWR(NVHOST_IOCTL_MAGIC, 14, struct nvhost_ctrl_get_characteristics)
#define NVHOST_IOCTL_CTRL_POLL_FD_CREATE \
	_IOR(NVHOST_IOCTL_MAGIC, 16, struct nvhost_ctrl_poll_fd_create_args)
#define NVHOST_IOCTL_CTRL_SYNC_FILE_EXTRACT \
	_IOWR(NVHOST_IOCTL_MAGIC, 19, struct nvhost_ctrl_sync_file_extract)

// Jetson Orin (Tegra234) hardware syncpoint count
#define ORIN_NUM_SYNCPTS 704

// ── Module state ──────────────────────────────────────────────────────────────

static struct {
	struct class  *class;
	struct cdev    cdev;
	struct device *dev;
	dev_t          devt;
} nvhost_shim;

// ── host1x device lookup ──────────────────────────────────────────────────────

static const struct of_device_id host1x_of_match[] = {
	{ .compatible = "nvidia,tegra234-host1x" },
	{ .compatible = "nvidia,tegra194-host1x" },
	{ .compatible = "nvidia,tegra186-host1x" },
	{},
};

static struct host1x *get_host1x(void)
{
	struct platform_device *pdev;
	struct device_node *np;
	void *drvdata;

	np = of_find_matching_node(NULL, host1x_of_match);
	if (!np) {
		pr_err_ratelimited("nvhost-ctrl-shim: no host1x OF node found\n");
		return ERR_PTR(-ENODEV);
	}

	pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!pdev) {
		pr_err_ratelimited("nvhost-ctrl-shim: no host1x platform_device\n");
		return ERR_PTR(-EAGAIN);
	}

	drvdata = platform_get_drvdata(pdev);
	if (!drvdata) {
		pr_err_ratelimited("nvhost-ctrl-shim: host1x drvdata is NULL\n");
		return ERR_PTR(-EAGAIN);
	}

	return drvdata;
}

// ── File operations ───────────────────────────────────────────────────────────

static int nvhost_ctrl_open(struct inode *inode, struct file *file)
{
	struct host1x *host1x = get_host1x();

	if (IS_ERR(host1x)) {
		pr_err("nvhost-ctrl-shim: open failed, get_host1x=%ld\n",
		       PTR_ERR(host1x));
		return PTR_ERR(host1x);
	}

	pr_debug("nvhost-ctrl-shim: opened (pid %d)\n", current->pid);
	file->private_data = host1x;
	return 0;
}

// ── NVHOST_IOCTL_CTRL_SYNCPT_READ / SYNCPT_READ_MAX ──────────────────────────

static int ioctl_syncpt_read(struct host1x *host1x, void __user *data,
			     bool read_max)
{
	struct nvhost_ctrl_syncpt_read_args args;
	struct host1x_syncpt *sp;

	if (copy_from_user(&args, data, sizeof(args)))
		return -EFAULT;

	sp = host1x_syncpt_get_by_id_noref(host1x, args.id);
	if (!sp) {
		pr_err_ratelimited("nvhost-ctrl-shim: SYNCPT_READ%s: id=%u not found\n",
				   read_max ? "_MAX" : "", args.id);
		return -EINVAL;
	}

	args.value = read_max ? host1x_syncpt_read_max(sp)
			      : host1x_syncpt_read(sp);

	return copy_to_user(data, &args, sizeof(args)) ? -EFAULT : 0;
}

// ── NVHOST_IOCTL_CTRL_SYNCPT_WAITMEX ─────────────────────────────────────────
// Blocking wait until syncpt[id].value >= thresh, using interrupt-driven
// dma_fence_wait_timeout (host1x hardware interrupt, NOT CPU busy-poll).

static int ioctl_syncpt_waitmex(struct host1x *host1x, void __user *data)
{
	struct nvhost_ctrl_syncpt_waitmex_args args;
	struct host1x_syncpt *sp;
	struct dma_fence *fence;
	long timeout_jiffies;
	long ret;

	if (copy_from_user(&args, data, sizeof(args)))
		return -EFAULT;

	pr_debug("nvhost-ctrl-shim: SYNCPT_WAITMEX id=%u thresh=%u timeout=%d\n",
		 args.id, args.thresh, args.timeout);

	sp = host1x_syncpt_get_by_id_noref(host1x, args.id);
	if (!sp) {
		pr_err("nvhost-ctrl-shim: SYNCPT_WAITMEX id=%u not found\n",
		       args.id);
		return -EINVAL;
	}

	// timeout: -1 → wait forever; 0 → wait forever; >0 → milliseconds.
	//
	// GA10B (Jetson Orin NX) is slower than desktop GPUs. CUDA's built-in
	// timeout for cudaStreamSynchronize may expire before large-model kernels
	// (e.g. qwen2.5:7b warmup with 311 MiB compute buffer) complete on GA10B.
	// Enforce a minimum wait of 30 s so slow-but-valid kernels are not aborted.
	// This also logs the CUDA-requested timeout for diagnostics.
	if (args.timeout < 0) {
		// -1 = wait forever
		timeout_jiffies = MAX_SCHEDULE_TIMEOUT;
	} else if (args.timeout == 0) {
		// 0 = also treat as "wait forever" (no timeout specified)
		timeout_jiffies = MAX_SCHEDULE_TIMEOUT;
	} else {
		// Clamp to minimum 30 000 ms so GA10B large-model kernels are not
		// prematurely killed by CUDA's default short timeout.
		unsigned int timeout_ms = max_t(unsigned int,
					        (unsigned int)args.timeout, 30000U);
		pr_debug("nvhost-ctrl-shim: SYNCPT_WAITMEX cuda_timeout=%dms → using %ums\n",
			 args.timeout, timeout_ms);
		timeout_jiffies = msecs_to_jiffies(timeout_ms);
	}

	// Create a fence that signals when syncpt reaches thresh
	fence = host1x_fence_create(sp, args.thresh, true);
	if (IS_ERR(fence)) {
		pr_err("nvhost-ctrl-shim: SYNCPT_WAITMEX fence_create failed: %ld\n",
		       PTR_ERR(fence));
		return PTR_ERR(fence);
	}

	// Sleep until hardware interrupt signals the fence
	ret = dma_fence_wait_timeout(fence, true, timeout_jiffies);
	dma_fence_put(fence);

	if (ret < 0) {
		pr_err("nvhost-ctrl-shim: SYNCPT_WAITMEX wait error: %ld\n", ret);
		return ret;
	}
	if (ret == 0) {
		pr_warn("nvhost-ctrl-shim: SYNCPT_WAITMEX timeout id=%u thresh=%u (cuda_timeout=%dms)\n",
			args.id, args.thresh, args.timeout);
		return -ETIMEDOUT;
	}

	args.value  = host1x_syncpt_read(sp);
	args.tv_sec = 0;
	args.tv_nsec = 0;

	pr_debug("nvhost-ctrl-shim: SYNCPT_WAITMEX done id=%u value=%u\n",
		 args.id, args.value);

	return copy_to_user(data, &args, sizeof(args)) ? -EFAULT : 0;
}

// ── NVHOST_IOCTL_CTRL_GET_CHARACTERISTICS ────────────────────────────────────
// CUDA calls this on every open to discover available syncpoints.

static int ioctl_get_characteristics(void __user *data)
{
	struct nvhost_ctrl_get_characteristics req;
	struct nvhost_characteristics chars = {
		.flags         = NVHOST_CHARACTERISTICS_SUPPORT_PREFENCES,
		.num_mlocks    = 0,
		.num_syncpts   = ORIN_NUM_SYNCPTS,
		.syncpts_base  = 0,
		.syncpts_limit = ORIN_NUM_SYNCPTS,
		.num_hw_pts    = ORIN_NUM_SYNCPTS,
		.padding       = 0,
	};
	__u64 copy_size;

	if (copy_from_user(&req, data, sizeof(req)))
		return -EFAULT;

	pr_debug("nvhost-ctrl-shim: GET_CHARACTERISTICS buf_size=%llu\n",
		 req.nvhost_characteristics_buf_size);

	if (!req.nvhost_characteristics_buf_addr) {
		// Only querying the required size
		req.nvhost_characteristics_buf_size = sizeof(chars);
		return copy_to_user(data, &req, sizeof(req)) ? -EFAULT : 0;
	}

	copy_size = min_t(__u64, req.nvhost_characteristics_buf_size, sizeof(chars));
	if (copy_to_user(u64_to_user_ptr(req.nvhost_characteristics_buf_addr),
			 &chars, copy_size))
		return -EFAULT;

	req.nvhost_characteristics_buf_size = sizeof(chars);
	return copy_to_user(data, &req, sizeof(req)) ? -EFAULT : 0;
}

// ── NVHOST_IOCTL_CTRL_POLL_FD_CREATE ─────────────────────────────────────────
// Creates an anonymous inode fd for syncpoint event polling.
// Called once by gk20a_scale_init (GPU frequency scaling); NOT in the CUDA
// inference hot-path. Returns a real pollable fd so callers can select()/epoll()
// without getting ENOTTY. The fd is a minimal anon inode — it does not deliver
// syncpoint threshold events, but it is a valid open file descriptor.

static __poll_t nvhost_ctrl_poll_fd_poll(struct file *file, poll_table *wait)
{
	/* Never signals readiness — callers use SYNCPT_WAITMEX for real waits */
	return 0;
}

static const struct file_operations nvhost_ctrl_poll_fops = {
	.owner = THIS_MODULE,
	.poll  = nvhost_ctrl_poll_fd_poll,
};

static int ioctl_poll_fd_create(void __user *data)
{
	struct nvhost_ctrl_poll_fd_create_args args;
	int fd;

	fd = anon_inode_getfd("nvhost-ctrl-poll", &nvhost_ctrl_poll_fops,
			      NULL, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		pr_err("nvhost-ctrl-shim: POLL_FD_CREATE: anon_inode_getfd failed: %d\n",
		       fd);
		return fd;
	}

	args.fd = fd;
	args.padding = 0;

	if (copy_to_user(data, &args, sizeof(args))) {
		close_fd(fd);
		return -EFAULT;
	}

	pr_debug("nvhost-ctrl-shim: POLL_FD_CREATE → fd=%d\n", fd);
	return 0;
}

// ── NVHOST_IOCTL_CTRL_SYNC_FENCE_CREATE ──────────────────────────────────────

static int make_fence_fd(struct host1x_syncpt *sp, u32 thresh)
{
	struct sync_file *sfile;
	struct dma_fence *f;
	int fd;

	f = host1x_fence_create(sp, thresh, true);
	if (IS_ERR(f)) {
		pr_err_ratelimited("nvhost-ctrl-shim: host1x_fence_create thresh=%u err=%ld\n",
				   thresh, PTR_ERR(f));
		return PTR_ERR(f);
	}

	fd = get_unused_fd_flags(O_CLOEXEC);
	if (fd < 0) {
		dma_fence_put(f);
		return fd;
	}

	sfile = sync_file_create(f);
	dma_fence_put(f);
	if (!sfile) {
		put_unused_fd(fd);
		return -ENOMEM;
	}

	fd_install(fd, sfile->file);
	return fd;
}

static int make_array_fence_fd(struct host1x *host1x,
				struct nvhost_ctrl_sync_fence_info __user *pts_user,
				u32 num_pts)
{
	struct dma_fence **fences;
	struct dma_fence_array *arr;
	struct sync_file *sfile;
	struct host1x_syncpt *sp;
	struct nvhost_ctrl_sync_fence_info pt;
	int fd, err = 0;
	u32 i;

	fences = kcalloc(num_pts, sizeof(*fences), GFP_KERNEL);
	if (!fences)
		return -ENOMEM;

	for (i = 0; i < num_pts; i++) {
		if (copy_from_user(&pt, pts_user + i, sizeof(pt))) {
			err = -EFAULT;
			goto free_fences;
		}
		sp = host1x_syncpt_get_by_id_noref(host1x, pt.id);
		if (!sp) {
			err = -EINVAL;
			goto free_fences;
		}
		fences[i] = host1x_fence_create(sp, pt.thresh, true);
		if (IS_ERR(fences[i])) {
			err = PTR_ERR(fences[i]);
			fences[i] = NULL;
			goto free_fences;
		}
	}

	/* dma_fence_array_create takes ownership of fences[] on success */
	arr = dma_fence_array_create(num_pts, fences,
				     dma_fence_context_alloc(1), 1, false);
	if (!arr) {
		err = -ENOMEM;
		goto free_fences;
	}

	fd = get_unused_fd_flags(O_CLOEXEC);
	if (fd < 0) {
		err = fd;
		dma_fence_put(&arr->base);
		return err;
	}

	sfile = sync_file_create(&arr->base);
	dma_fence_put(&arr->base);
	if (!sfile) {
		put_unused_fd(fd);
		return -ENOMEM;
	}

	fd_install(fd, sfile->file);
	return fd;

free_fences:
	for (i = 0; i < num_pts; i++)
		if (fences[i])
			dma_fence_put(fences[i]);
	kfree(fences);
	return err;
}

static int ioctl_sync_fence_create(struct host1x *host1x, void __user *data)
{
	struct nvhost_ctrl_sync_fence_info __user *pts_user;
	struct nvhost_ctrl_sync_fence_create_args args;
	struct nvhost_ctrl_sync_fence_info pt;
	struct host1x_syncpt *sp;
	int fd;

	if (copy_from_user(&args, data, sizeof(args)))
		return -EFAULT;

	pr_debug("nvhost-ctrl-shim: SYNC_FENCE_CREATE num_pts=%u\n", args.num_pts);

	if (args.num_pts == 0 || args.num_pts > 512)
		return -EINVAL;

	pts_user = u64_to_user_ptr(args.pts);

	if (args.num_pts == 1) {
		if (copy_from_user(&pt, pts_user, sizeof(pt)))
			return -EFAULT;
		pr_debug("nvhost-ctrl-shim: SYNC_FENCE_CREATE id=%u thresh=%u\n",
			 pt.id, pt.thresh);
		sp = host1x_syncpt_get_by_id_noref(host1x, pt.id);
		if (!sp) {
			pr_err("nvhost-ctrl-shim: SYNC_FENCE_CREATE id=%u not found\n",
			       pt.id);
			return -EINVAL;
		}
		fd = make_fence_fd(sp, pt.thresh);
	} else {
		fd = make_array_fence_fd(host1x, pts_user, args.num_pts);
	}

	if (fd < 0) {
		pr_err("nvhost-ctrl-shim: SYNC_FENCE_CREATE failed: %d\n", fd);
		return fd;
	}

	pr_debug("nvhost-ctrl-shim: SYNC_FENCE_CREATE → fd=%d\n", fd);
	args.fence_fd = fd;
	if (copy_to_user(data, &args, sizeof(args))) {
		close_fd(fd);
		return -EFAULT;
	}
	return 0;
}

// ── NVHOST_IOCTL_CTRL_SYNC_FILE_EXTRACT ──────────────────────────────────────

static int ioctl_sync_file_extract(struct host1x *host1x, void __user *data)
{
	struct nvhost_ctrl_sync_fence_info __user *fences_user;
	struct nvhost_ctrl_sync_file_extract args;
	struct dma_fence *fence, **fences;
	struct dma_fence_array *array;
	unsigned int num_fences, i, j;
	int err = 0;

	if (copy_from_user(&args, data, sizeof(args)))
		return -EFAULT;

	fences_user = u64_to_user_ptr(args.fences_ptr);

	fence = sync_file_get_fence(args.fd);
	if (!fence)
		return -EINVAL;

	array = to_dma_fence_array(fence);
	if (array) {
		fences = array->fences;
		num_fences = array->num_fences;
	} else {
		fences = &fence;
		num_fences = 1;
	}

	for (i = 0, j = 0; i < num_fences; i++) {
		struct nvhost_ctrl_sync_fence_info fi;

		err = host1x_fence_extract(fences[i], &fi.id, &fi.thresh);
		if (err == -EINVAL && dma_fence_is_signaled(fences[i])) {
			/* signaled stub fence — skip */
			err = 0;
			continue;
		}
		if (err)
			goto put;

		if (j < args.num_fences) {
			if (copy_to_user(fences_user + j, &fi, sizeof(fi))) {
				err = -EFAULT;
				goto put;
			}
		}
		j++;
	}

	args.num_fences = j;
	if (copy_to_user(data, &args, sizeof(args)))
		err = -EFAULT;

put:
	dma_fence_put(fence);
	return err;
}

// ── Ioctl dispatcher ──────────────────────────────────────────────────────────

static long nvhost_ctrl_ioctl(struct file *file, unsigned int cmd,
			      unsigned long arg)
{
	struct host1x *host1x = file->private_data;
	void __user *data = (void __user *)arg;

	switch (cmd) {
	case NVHOST_IOCTL_CTRL_GET_VERSION: {
		struct nvhost_get_param_args v = { .value = 1 };
		pr_debug("nvhost-ctrl-shim: GET_VERSION → 1\n");
		return copy_to_user(data, &v, sizeof(v)) ? -EFAULT : 0;
	}
	case NVHOST_IOCTL_CTRL_SYNCPT_READ:
		return ioctl_syncpt_read(host1x, data, false);
	case NVHOST_IOCTL_CTRL_SYNCPT_READ_MAX:
		return ioctl_syncpt_read(host1x, data, true);
	case NVHOST_IOCTL_CTRL_SYNCPT_WAITMEX:
		return ioctl_syncpt_waitmex(host1x, data);
	case NVHOST_IOCTL_CTRL_SYNC_FENCE_CREATE:
		return ioctl_sync_fence_create(host1x, data);
	case NVHOST_IOCTL_CTRL_GET_CHARACTERISTICS:
		return ioctl_get_characteristics(data);
	case NVHOST_IOCTL_CTRL_POLL_FD_CREATE:
		return ioctl_poll_fd_create(data);
	case NVHOST_IOCTL_CTRL_SYNC_FILE_EXTRACT:
		return ioctl_sync_file_extract(host1x, data);
	default:
		pr_warn_ratelimited("nvhost-ctrl-shim: unknown ioctl cmd=0x%08x\n", cmd);
		return -ENOTTY;
	}
}

// ── Device class / cdev setup ─────────────────────────────────────────────────

static char *nvhost_ctrl_devnode(const struct device *dev, umode_t *mode)
{
	*mode = 0666;
	return NULL;
}

static const struct file_operations nvhost_ctrl_fops = {
	.owner          = THIS_MODULE,
	.open           = nvhost_ctrl_open,
	.unlocked_ioctl = nvhost_ctrl_ioctl,
	.compat_ioctl   = nvhost_ctrl_ioctl,
};

// ── Module init / exit ────────────────────────────────────────────────────────

static int __init nvhost_ctrl_shim_init(void)
{
	dev_t devt;
	int err;

	err = alloc_chrdev_region(&devt, 0, 1, "nvhost-ctrl");
	if (err)
		return err;

	nvhost_shim.class = class_create("nvhost-ctrl");
	if (IS_ERR(nvhost_shim.class)) {
		err = PTR_ERR(nvhost_shim.class);
		goto unregister;
	}
	nvhost_shim.class->devnode = nvhost_ctrl_devnode;

	cdev_init(&nvhost_shim.cdev, &nvhost_ctrl_fops);
	err = cdev_add(&nvhost_shim.cdev, devt, 1);
	if (err)
		goto destroy_class;

	nvhost_shim.dev = device_create(nvhost_shim.class, NULL,
					devt, NULL, "nvhost-ctrl");
	if (IS_ERR(nvhost_shim.dev)) {
		err = PTR_ERR(nvhost_shim.dev);
		goto del_cdev;
	}

	nvhost_shim.devt = devt;
	pr_info("nvhost-ctrl-shim: /dev/nvhost-ctrl ready (major %d)\n",
		MAJOR(devt));
	return 0;

del_cdev:
	cdev_del(&nvhost_shim.cdev);
destroy_class:
	class_destroy(nvhost_shim.class);
unregister:
	unregister_chrdev_region(devt, 1);
	return err;
}

static void __exit nvhost_ctrl_shim_exit(void)
{
	device_destroy(nvhost_shim.class, nvhost_shim.devt);
	cdev_del(&nvhost_shim.cdev);
	class_destroy(nvhost_shim.class);
	unregister_chrdev_region(nvhost_shim.devt, 1);
}

module_init(nvhost_ctrl_shim_init);
module_exit(nvhost_ctrl_shim_exit);

MODULE_DESCRIPTION("nvhost-ctrl shim — NVHOST ioctl API over OOT host1x for Talos Jetson");
MODULE_LICENSE("GPL");
