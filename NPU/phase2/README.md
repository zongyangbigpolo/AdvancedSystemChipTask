# NPU Phase 2：模型转换与离线推理

[方向入口与公共环境](../README.md) · [名词与缩写](../../glossary/README.md)

[Phase 1](../phase1/README.md) · [Phase 2](../phase2/README.md) · [Phase 3](../phase3/README.md) · [Phase 4](../phase4/README.md) · [Phase 5](../phase5/README.md)

本阶段先固定静态 shape 完成模型闭环，再增加动态输入。需要支持 ATC 和对应 OM 运行的设备，torch_npu 不是 OM 执行接口。

## 1. Task list

| 状态 | 任务名称 | 目的 | 方法 | 硬件 | 方案与原因 |
| --- | --- | --- | --- | --- | --- |
| [ ] | NPU-P2-01 导出可复现模型 | 固定权重、输入与参考结果 | PyTorch 小型 MLP 导出 ONNX，checker 与 CPU runtime 验证 | 导出可在 CPU；推理需 NPU | 无外部数据下载依赖，先排除预处理与权重差异 |
| [ ] | NPU-P2-02 ATC 编译模型 | 理解目标 SoC 与算子支持 | 指定真实 soc_version、shape、opset，保留编译日志 | 支持的编译主机与目标 NPU | OM 面向目标设备，不能跨产品随意复用 |
| [ ] | NPU-P2-03 AscendCL 离线推理 | 建立输入到输出的执行闭环 | 查询模型描述、分配 buffer、拷贝、执行与校验 | 支持该 OM 的设备 | 按运行时描述分配，不猜测 dtype 或布局 |
| [ ] | NPU-P2-04 动态 shape 与部署包 | 学习模型可变输入及部署约束 | 固定 batch 对照、受支持动态档位、清单与散列 | 支持相应动态能力的设备 | 从静态基线逐步扩展，避免编译和运行 shape 不一致 |

## 2. NPU-P2-01：生成模型和参考数据

在匹配版本的 PyTorch、ONNX 环境中运行以下导出程序。较新 PyTorch 的 ONNX 导出器默认行为可能变化，应固定包版本并登记实际导出方式；本例使用显式传统导出路径。

```bash
python - <<'PY'
import os
from pathlib import Path
import numpy as np
import onnx
import torch

root = Path(os.environ["LAB"])
torch.manual_seed(2026)
model = torch.nn.Sequential(
    torch.nn.Linear(128, 256), torch.nn.ReLU(), torch.nn.Linear(256, 16)
).eval()
x = torch.randn(1, 128)
with torch.no_grad():
    y = model(x)
torch.save(model.state_dict(), root / "models/mlp.pt")
torch.onnx.export(model, x, str(root / "models/mlp.onnx"),
                  input_names=["input"], output_names=["output"],
                  opset_version=13, dynamo=False)
onnx.checker.check_model(onnx.load(str(root / "models/mlp.onnx")))
np.save(root / "data/input.npy", x.numpy())
np.save(root / "data/reference.npy", y.numpy())
x.numpy().astype("<f4").tofile(root / "data/input.bin")
print("input:", tuple(x.shape), "output:", tuple(y.shape))
PY
```

在 CPU ONNX Runtime 中加载 ONNX，读取同一 `input.npy`，按输出名称取值，与 `reference.npy` 比较并保存误差。若输入已改变、opset 不受 ATC 支持或输出对不上，先修复导出，不继续优化。

## 3. NPU-P2-02：编译为 OM

从实际设备与版本文档确认 `SOC_VERSION`；不是简单复制板卡营销名称。核对 `atc --help` 后，在 CANN 环境内：

```bash
atc --model="$LAB/models/mlp.onnx" --framework=5 \
  --output="$LAB/models/mlp" \
  --input_shape="input:1,128" \
  --soc_version="${SOC_VERSION:?未设置实际目标 SoC}"
sha256sum "$LAB/models/mlp.onnx" "$LAB/models/mlp.om"
```

保存 ATC 完整命令、返回值、stdout/stderr、模型输入输出及融合信息。编译失败时按不支持算子、shape 推导、opset、工具链版本分别定位；更换精度或算子实现后生成新的产物编号，不能覆盖原基线。

## 4. NPU-P2-03：离线执行方法

从 [AscendCL 官方样例](https://github.com/Ascend/samples) 选择与 CANN/SoC 兼容的模型执行样例并固定 commit；分类后处理样例需移除特定图像/标签假设，不能把二进制输入当图片输入。按该样例 README 构建，或编写最小 AscendCL loader，必须覆盖：

1. 初始化、设置逻辑 device ID、创建 context/stream，加载本阶段 OM。
2. 查询模型输入输出数量、名称、shape、format、dtype 和字节数；本模型逻辑输入为 `[1,128]` FP32，但实际 buffer 以模型描述为准。
3. 检查 `input.bin` 大小与布局；根据运行模式分配内存、执行必要 H2D，构造输入输出 dataset。
4. 执行 `aclmdlExecute`，或异步执行后同步 stream，再按运行模式拷回输出。
5. 将输出按查询到的 dtype/shape 解码，保存原始 buffer 与误差，按逆序释放 dataset、buffer、模型、stream/context 及 runtime。

每个 API 检查返回码；异常路径也释放已获得资源，不以全零输出替代失败。具体编译和启动参数依所选样例，记录实际路径，不虚构一个现成的通用执行二进制。

同一输入比较 PyTorch CPU、ONNX Runtime CPU、OM 三条路径。对 FP32/FP16 实际执行模式分别设容差，报告最大绝对误差、相对误差与非有限值；随机 MLP 没有分类标签，不报告 Top-1 准确率。

## 5. NPU-P2-04：动态输入与交付

先分别导出 batch=1/8/32 的静态模型，均使用相同权重；再按所选 ATC 版本支持的动态 batch/shape 参数导出动态模型并在运行时设置档位。固定静态导出的模型不能只改 ATC 输入声明就当成动态模型。测试合法档位、未支持档位和输入字节数错误；无效输入须明确失败。

部署包包括 ONNX、OM、权重、输入输出规范、loader 源码、依赖清单、ATC 日志、散列与运行说明。大模型和二进制产物放实验存储；不打包私钥、固定凭据或未获授权分发的模型。
