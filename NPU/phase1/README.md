# NPU Phase 1：架构、环境与单卡验证

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

所有任务待执行；缺少支持的硬件时只完成调研和配置规划。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | NPU-P1-01 架构与产品能力调研 | 确认推理、训练和算子能力边界 | 对比 CPU/GPU/NPU，查询 SoC、AI Core 与内存结构 | Ascend 310/310P、910 系列作型号对照 | 以具体产品能力而非标称 TOPS 选择平台 |
| [ ] | NPU-P1-02 驱动与框架安装 | 建立可复现的软件栈 | 产品兼容表、驱动/固件、CANN、Python 虚拟环境 | 受支持的 Ascend 主机与板卡 | 固定配套版本，避免内核驱动和用户态库不匹配 |
| [ ] | NPU-P1-03 单卡正确性闭环 | 确认张量确实在 NPU 执行 | CPU 参考、NPU 矩阵计算、同步、误差检查 | 支持 torch_npu 的设备 | 不把 import 成功或设备枚举当作计算通过 |
| [ ] | NPU-P1-04 设备资源与生命周期 | 理解内存、stream 和上下文 | 重复分配/计算/释放，采集进程与内存状态 | 同上 | 区分内存缓存和泄漏，形成后续计时基线 |

## 2. NPU-P1-01：硬件选型与数据路径

绘制 `框架 → torch_npu → CANN/算子库 → 设备` 和 `ONNX → ATC → OM → AscendCL` 两条路径，标出主机内存、设备内存、数据拷贝、图编译和执行位置。查清实际产品的矩阵、向量与数据搬运单元，以及支持的数据类型。

建立型号能力表：推理/训练、torch_npu、Ascend C、HCCL、板内/跨板互连、内存容量、主机架构。Intel 客户端 NPU 可按 OpenVINO 路线另作对照，但不将其驱动或模型格式视为 Ascend 的替代品。

## 3. NPU-P1-02：安装与环境核对

由管理员按选定产品安装驱动和固件，重启要求以该产品指南为准。健康检查通过后安装匹配 CANN，并确认 Toolkit、运行库、算子包完整。禁止在有其他作业时直接升级。

在独立 Python 虚拟环境中安装兼容表规定的包，先设置实际版本参数：

```bash
python3 -m venv "$LAB/venv"
source "$LAB/venv/bin/activate"
# TORCH_VERSION、TORCH_NPU_VERSION 必须先按已核对的映射设置。
python -m pip install "torch==${TORCH_VERSION:?未设置 PyTorch 版本}" \
  "torch-npu==${TORCH_NPU_VERSION:?未设置 torch_npu 版本}"
python -m pip check
python -m pip freeze > "$LAB/results/python-packages.txt"
python -c 'import torch, torch_npu; print(torch.__version__); print(torch_npu.__version__); print(torch.npu.device_count())'
```

包来源、Python ABI、CPU 架构和 PyTorch wheel 类型按该版本安装说明选择；x86 环境可能需要官方 CPU wheel 源，不能误用 CUDA wheel。上例是版本参数模板，不代替相应产品安装指南。

## 4. NPU-P1-03：矩阵正确性

以下代码在配套框架与设备就绪后执行；使用小整数输入便于排查精度和格式问题：

```bash
python - <<'PY'
import torch
import torch_npu

if not torch.npu.is_available():
    raise RuntimeError("NPU unavailable")
torch.npu.set_device(0)
a = torch.arange(16, dtype=torch.float32).reshape(4, 4)
b = torch.eye(4, dtype=torch.float32)
reference = a @ b
actual_device = a.to("npu:0") @ b.to("npu:0")
torch.npu.synchronize()
assert actual_device.device.type == "npu"
actual = actual_device.cpu()
torch.testing.assert_close(actual, reference, rtol=1e-5, atol=1e-5)
print("device:", actual_device.device)
print("max_abs_error:", (actual - reference).abs().max().item())
PY
```

随后增加随机矩阵和非方阵；根据实际计算模式预先设置容差，记录是否使用降精度矩阵计算。任何不支持的 dtype/算子都作为能力限制，不静默转到 CPU 后宣称 NPU 通过。

## 5. NPU-P1-04：资源记录与交付

在相同进程内循环 100 次分配、矩阵计算、同步与释放，分别记录首轮和稳定后的内存；再正常结束进程检查设备占用。框架缓存保留不直接视为泄漏，只有持续增长、无法复用或退出后异常占用才进一步定位。

若使用 AscendCL，按所选版本明确 `aclInit`、设备/context/stream 创建、内存分配、同步及逆序释放，检查每个 API 返回码。交付兼容性清单、设备映射、完整安装版本、CPU/NPU 误差日志及内存时间序列，不填写未经执行的通过结论。
