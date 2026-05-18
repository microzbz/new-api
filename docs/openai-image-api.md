# 图片接口：文生图、图生图与异步查询

本文档整理当前已验证可用的 OpenAI 兼容图片接口，适合直接提供给下游接入方。当前线上实测规格以 `gpt-image-2`、`1K`、`1024x1024` 为准；`2K` / `4K` 暂不写入对外接入文档，避免调用方按未验证规格对接。

## 基础信息

- Base URL（生产）：`http://45.78.4.80:17200/v1`
- Base URL（本地开发）：`http://127.0.0.1:17200/v1`
- 鉴权：`Authorization: Bearer sk-xxx`
- 模型：`gpt-image-2`
- 当前建议尺寸：`1024x1024`
- 当前计费：`400` cost points，即 `4` 点 / 张
- 默认同步返回结果；传 `async=true` 时立即返回任务，再轮询查询

## 接口总览

| 场景 | 方法 | 路径 | 说明 |
| --- | --- | --- | --- |
| 文生图 | `POST` | `/v1/images/generations` | 不传参考图，只传 `prompt` |
| 图生图 / 图片编辑 | `POST` | `/v1/images/edits` | 必须提供 `image`、`images` 或 `ref_assets` |
| 图生图兼容入口 | `POST` | `/v1/images/generations` | 传参考图时也会按图生图处理 |
| 图片任务查询 | `GET` | `/v1/images/generations/{task_id}` | 用于查询 generations 和 edits 创建的任务 |

注意：

- `GET /v1/images/edits/{task_id}` 当前不存在，会返回 `404`
- 图片任务统一使用 `GET /v1/images/generations/{task_id}` 查询
- 任务查询接口为状态查询，不扣费

## 通用参数

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `model` | string | 否 | 默认 `gpt-image-2` |
| `prompt` | string | 是 | 生成或编辑提示词 |
| `n` / `count` | number | 否 | 出图数量，默认 `1`，最大 `4` |
| `size` | string | 否 | 当前建议 `1024x1024` |
| `quality` | string | 否 | 可传 `low`、`medium`、`high`、`standard`、`hd` |
| `response_format` | string | 否 | 当前返回 URL 形式，建议传 `url` |
| `async` | boolean | 否 | `true` 时异步返回任务 |
| `image` | string/file | 图生图必填其一 | 单张参考图；支持 URL、`data:` URL、文件上传 |
| `images` | array/file[] | 图生图必填其一 | 多张参考图 |
| `ref_assets` | array/file[] | 图生图必填其一 | 多张参考图，业务侧也可使用该字段 |
| `mask` | string/file | 否 | 遮罩图，当前透传 |

## 文生图：同步

```bash
curl http://45.78.4.80:17200/v1/images/generations \
  -H "Authorization: Bearer sk-xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-image-2",
    "prompt": "A minimalist product advertisement with a fried chicken bucket placed on a clean white podium.",
    "n": 1,
    "size": "1024x1024",
    "response_format": "url"
  }'
```

成功返回示例：

```json
{
  "created": 1778743972,
  "data": [
    {
      "url": "/api/v1/gen/cached/generated/2026/05/14/4dd371f1a3ab4425855d8eb5f6_0.png",
      "width": 1024,
      "height": 1024
    }
  ],
  "task_id": "4dd371f1a3ab4425855d8eb5f6",
  "usage": {
    "total_cost": 400,
    "total_points": 4
  }
}
```

## 图生图：图片 URL

```bash
curl http://45.78.4.80:17200/v1/images/edits \
  -H "Authorization: Bearer sk-xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-image-2",
    "prompt": "turn this reference image into a clean watercolor postcard",
    "image": "https://placehold.co/512x512/png",
    "size": "1024x1024",
    "response_format": "url"
  }'
```

## 图生图：base64 / data URL

`image` 可直接传 `data:image/png;base64,...`。

```bash
B64=$(base64 < input.png | tr -d '\n')

curl http://45.78.4.80:17200/v1/images/edits \
  -H "Authorization: Bearer sk-xxx" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-image-2\",
    \"prompt\": \"turn this base64 reference image into a soft watercolor postcard\",
    \"image\": \"data:image/png;base64,$B64\",
    \"size\": \"1024x1024\",
    \"response_format\": \"url\"
  }"
```

## 图生图：multipart/form-data 上传文件

```bash
curl http://45.78.4.80:17200/v1/images/edits \
  -H "Authorization: Bearer sk-xxx" \
  -F "model=gpt-image-2" \
  -F "prompt=turn this uploaded multipart image into a clean watercolor postcard" \
  -F "size=1024x1024" \
  -F "response_format=url" \
  -F "image=@./input.png;type=image/png"
```

多图字段也支持表单文件：

```bash
curl http://45.78.4.80:17200/v1/images/edits \
  -H "Authorization: Bearer sk-xxx" \
  -F "model=gpt-image-2" \
  -F "prompt=combine these references into a clean product poster" \
  -F "size=1024x1024" \
  -F "images=@./ref-1.png;type=image/png" \
  -F "images=@./ref-2.png;type=image/png"
```

## 图生图兼容入口：`/v1/images/generations`

`/v1/images/generations` 传入 `image`、`images` 或 `ref_assets` 时，也会按图生图处理。

```bash
curl http://45.78.4.80:17200/v1/images/generations \
  -H "Authorization: Bearer sk-xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-image-2",
    "prompt": "保持主体不变，改成蓝色调极简图标风格",
    "image": "https://placehold.co/512x512/png",
    "n": 1,
    "size": "1024x1024"
  }'
```

语义上仍建议图生图优先使用 `/v1/images/edits`。

## 异步创建

任意图片创建请求都可以传 `async=true`。异步请求会立即返回任务，不等待图片生成完成。

```bash
curl http://45.78.4.80:17200/v1/images/edits \
  -H "Authorization: Bearer sk-xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-image-2",
    "prompt": "turn this async reference image into a soft watercolor postcard",
    "image": "https://placehold.co/512x512/png",
    "size": "1024x1024",
    "response_format": "url",
    "async": true
  }'
```

异步创建返回示例：

```json
{
  "id": "98e1c91da2dd4ed79a3aed8885",
  "object": "image.generation.task",
  "task_id": "98e1c91da2dd4ed79a3aed8885",
  "kind": "image",
  "mode": "i2i",
  "model": "gpt-image-2",
  "status": "queued",
  "progress": 0,
  "usage": {
    "total_cost": 400,
    "total_points": 4
  }
}
```

## 查询异步任务

```bash
curl http://45.78.4.80:17200/v1/images/generations/98e1c91da2dd4ed79a3aed8885 \
  -H "Authorization: Bearer sk-xxx"
```

运行中返回示例：

```json
{
  "id": "98e1c91da2dd4ed79a3aed8885",
  "object": "image.generation.task",
  "task_id": "98e1c91da2dd4ed79a3aed8885",
  "status": "running",
  "progress": 5,
  "usage": {
    "total_cost": 400,
    "total_points": 4
  }
}
```

完成返回示例：

```json
{
  "id": "98e1c91da2dd4ed79a3aed8885",
  "object": "image.generation.task",
  "task_id": "98e1c91da2dd4ed79a3aed8885",
  "status": "succeeded",
  "progress": 100,
  "result": {
    "created": 1778748454,
    "task_id": "98e1c91da2dd4ed79a3aed8885",
    "data": [
      {
        "url": "/api/v1/gen/cached/generated/2026/05/14/98e1c91da2dd4ed79a3aed8885_0.png",
        "width": 1024,
        "height": 1024
      }
    ],
    "usage": {
      "total_cost": 400,
      "total_points": 4
    }
  },
  "usage": {
    "total_cost": 400,
    "total_points": 4
  }
}
```

## 状态说明

| 状态 | 含义 |
| --- | --- |
| `queued` | 已创建任务，等待 worker 执行 |
| `running` | 生成中 |
| `succeeded` | 已完成，`result.data` 中包含图片 URL |
| `failed` | 失败，查看 `error` |
| `refunded` | 已退款 |

## 错误与注意事项

- 当前线上实测只确认 `1K / 1024x1024` 稳定可用
- `2K`、`4K` 暂不建议对外承诺；账号能力和上游限制可能导致不可用
- 图片结果 URL 可能是相对路径，例如 `/api/v1/gen/cached/...`，调用方需要按服务域名拼成完整 URL
- 图生图必须提供至少一张参考图，否则 `/v1/images/edits` 会返回参数错误
- 余额不足时返回 `点数不足`
- 没有可用 GPT 图片账号时，会返回 provider 或账号池相关错误
- `GET /v1/images/edits/{task_id}` 当前不存在，不要用这个路径轮询

## 推荐接入方式

1. 文生图统一调用 `POST /v1/images/generations`
2. 图生图优先调用 `POST /v1/images/edits`
3. 需要快速返回任务时，创建时加 `async=true`
4. 异步任务统一用 `GET /v1/images/generations/{task_id}` 查询
5. 当前默认按 `gpt-image-2 + 1024x1024 + response_format=url` 接入最稳妥
