#!/usr/bin/env python3
"""
Patch nvgpu_nvhost_get_syncpt_client_managed() in nvhost_host1x.c to add a
retry loop for GA10B syncpt allocation failures during GR init window.

GA10B ERRATA_SYNCPT_INVALID_ID_0: nvgpu rejects syncpt id=0. During ~1-2ms
after the first kernel submit, host1x_syncpt_alloc may return NULL, causing
CUDA error 999 on cudaStreamSynchronize. The retry loop waits up to 5ms.
"""
import sys

FNAME = "/oot-src/nvgpu/drivers/gpu/nvgpu/os/linux/nvhost_host1x.c"

OLD = """\
u32 nvgpu_nvhost_get_syncpt_client_managed(struct nvgpu_nvhost_dev *nvhost_dev,
					   const char *syncpt_name)
{
	struct host1x_syncpt *sp;
	struct host1x *host1x;

	host1x = platform_get_drvdata(nvhost_dev->host1x_pdev);
	if (!host1x)
		return 0;

	sp = host1x_syncpt_alloc(host1x, HOST1X_SYNCPT_CLIENT_MANAGED | HOST1X_SYNCPT_GPU,
				 syncpt_name);
	if (!sp)
		return 0;

	return host1x_syncpt_id(sp);
}\
"""

NEW = """\
u32 nvgpu_nvhost_get_syncpt_client_managed(struct nvgpu_nvhost_dev *nvhost_dev,
			   const char *syncpt_name)
{
	struct host1x_syncpt *sp = NULL;
	struct host1x *host1x;
	int retry;

	/* nvgpu 5.10.2: retry up to 5ms when host1x syncpt alloc fails during GR init window.
	 * GA10B ERRATA_SYNCPT_INVALID_ID_0 rejects id=0; during ~1-2ms after first kernel submit
	 * host1x_syncpt_alloc may return NULL, causing CUDA error 999 on cudaStreamSynchronize. */
	for (retry = 0; retry < 5; retry++) {
		host1x = platform_get_drvdata(nvhost_dev->host1x_pdev);
		if (!host1x) {
			pr_warn_ratelimited("nvgpu: host1x not ready, syncpt retry %d/5\\n", retry + 1);
			msleep(1);
			continue;
		}
		sp = host1x_syncpt_alloc(host1x,
				HOST1X_SYNCPT_CLIENT_MANAGED | HOST1X_SYNCPT_GPU,
				syncpt_name);
		if (sp)
			break;
		pr_warn_ratelimited("nvgpu: syncpt_alloc NULL, retry %d/5\\n", retry + 1);
		msleep(1);
	}
	if (!sp) {
		pr_err_ratelimited("nvgpu: get_syncpt_client_managed: failed after retries\\n");
		return 0;
	}
	return host1x_syncpt_id(sp);
}\
"""

content = open(FNAME).read()
if OLD not in content:
    print(f"ERROR: pattern not found in {FNAME}", file=sys.stderr)
    sys.exit(1)

content = content.replace(OLD, NEW, 1)
open(FNAME, "w").write(content)
print("Patched nvhost_host1x.c: retry loop in nvgpu_nvhost_get_syncpt_client_managed")
