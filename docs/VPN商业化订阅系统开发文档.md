# VPN 商业化订阅系统 - 开发部署文档

## 目录

1. [项目概述](#1-项目概述)
2. [系统架构](#2-系统架构)
3. [技术选型](#3-技术选型)
4. [服务器准备](#4-服务器准备)
5. [数据库设计](#5-数据库设计)
6. [3X-UI 配置](#6-3x-ui-配置)
7. [后端开发](#7-后端开发)
8. [前端开发](#8-前端开发)
9. [支付对接](#9-支付对接)
10. [自动开通逻辑](#10-自动开通逻辑)
11. [部署指南](#11-部署指南)
12. [运维指南](#12-运维指南)
13. [安全建议](#13-安全建议)

---

## 1. 项目概述

### 1.1 项目背景

本文档详细说明如何基于 3X-UI 开发一个独立的商业化 VPN 订阅系统。用户可以通过网页注册、购买套餐、在线支付，自动开通 VPN 服务。

### 1.2 核心功能

| 功能模块 | 说明 |
|---------|------|
| 用户系统 | QQ邮箱/Google邮箱注册登录，验证码认证 |
| 套餐管理 | 多种套餐配置（按流量/按时长/按设备数） |
| 订单管理 | 订单创建、支付、取消、退款 |
| 支付系统 | 对接虎皮椒/Stripe/易支付等支付平台 |
| 自动开通 | 支付成功后自动创建用户、分配节点、重启Xray |
| 订阅管理 | 用户查看订阅状态、续费、下载配置 |
| 邮件通知 | 注册验证、支付成功、到期提醒 |

### 1.3 系统组件

```
┌─────────────────────────────────────────────────────────────────┐
│                        用户访问层                                 │
│                    (H5 响应式网页)                               │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                       商业化网站后端                              │
│              (用户管理 + 订单系统 + 支付回调)                      │
└─────────────────────────────────────────────────────────────────┘
                                │
                                │ HTTP API (Bearer Token)
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                        3X-UI 服务                               │
│               (节点管理 + 用户认证 + Xray控制)                     │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Xray-core                                │
│                       (VPN 服务)                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. 系统架构

### 2.1 整体架构图

```
                                    ┌─────────────────┐
                                    │     用户浏览器   │
                                    │   (手机/电脑)   │
                                    └────────┬────────┘
                                             │
                                    ┌────────▼────────┐
                                    │   Nginx/CDN     │
                                    │   (SSL 终结)    │
                                    └────────┬────────┘
                                             │
                    ┌────────────────────────┼────────────────────────┐
                    │                        │                        │
           ┌────────▼────────┐       ┌────────▼────────┐       ┌─────▼─────┐
           │  商业化网站前端  │       │  商业化网站后端  │       │  支付平台  │
           │   (Vue H5)      │       │   (Go/NestJS)   │       │ (虎皮椒)  │
           │   :3000        │       │   :8080         │       └─────┬─────┘
           └─────────────────┘       └────────┬────────┘             │
                                              │                       │
                                              │  HTTP API              │ 回调通知
                                              │  Bearer Token          │
                                              ▼                       │
                              ┌───────────────────────────────────────┘
                              │
                     ┌────────▼────────┐
                     │   3X-UI 服务    │
                     │    :2053        │
                     │  + SQLite DB    │
                     └────────┬────────┘
                              │
                              ▼
                     ┌────────────────┐
                     │  Xray-core     │
                     │  (VPN 核心)    │
                     └────────────────┘
```

### 2.2 数据流向

```
用户注册 → 创建账户 → 选择套餐 → 创建订单 → 跳转支付
                                                     │
                                                     ▼
用户收到订阅链接 ← 发送邮件 ← 生成订阅 ← 重启Xray ← 自动开通
                    │
                    ▼
              更新订单状态
```

---

## 3. 技术选型

### 3.1 后端技术栈

| 组件 | 推荐方案 | 说明 |
|------|----------|------|
| 语言 | Go / Node.js | 推荐 Go，与 3X-UI 一致 |
| 框架 | Gin / Echo / NestJS | 轻量高性能 |
| 数据库 | PostgreSQL | 商业数据存储 |
| 缓存 | Redis | 会话缓存、队列 |
| ORM | GORM / Prisma | 数据库操作 |
| 邮件 | SendGrid / QQ企业邮箱 | 发送通知 |

### 3.2 前端技术栈

| 组件 | 推荐方案 | 说明 |
|------|----------|------|
| 框架 | Vue 3 + Vite | 现代化开发体验 |
| UI库 | Vant 4 | 移动端 H5 专用 |
| 状态 | Pinia | Vue 3 官方推荐 |
| 路由 | Vue Router 4 | SPA 路由 |
| HTTP | Axios | API 请求 |

### 3.3 基础设施

| 组件 | 推荐方案 | 说明 |
|------|----------|------|
| 服务器 | Ubuntu 22.04 LTS | 稳定长期支持 |
| Web服务器 | Nginx | 反向代理、静态服务 |
| SSL | Let's Encrypt | 免费自动续期 |
| 进程管理 | PM2 / Supervisor | 守护进程 |

---

## 4. 服务器准备

### 4.1 服务器要求

| 配置 | 最低配置 | 推荐配置 |
|------|----------|----------|
| CPU | 1核 | 2核+ |
| 内存 | 1GB | 2GB+ |
| 硬盘 | 20GB | 40GB+ |
| 带宽 | 1Mbps | 5Mbps+ |
| 系统 | Ubuntu 20.04+ | Ubuntu 22.04 LTS |

### 4.2 端口规划

| 端口 | 服务 | 说明 |
|------|------|------|
| 80 | Nginx | HTTP (重定向到 HTTPS) |
| 443 | Nginx | HTTPS |
| 2053 | 3X-UI | 面板访问 |
| 5432 | PostgreSQL | 数据库 |
| 6379 | Redis | 缓存 |
| 8080 | 商业后台 | API 服务 |
| 3000 | 商业前端 | 前端开发/预览 |

### 4.3 环境安装

```bash
# 更新系统
sudo apt update && sudo apt upgrade -y

# 安装基础工具
sudo apt install -y curl wget git vim unzip ufw certbot

# 安装 Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

# 安装 Go
wget https://go.dev/dl/go1.21.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc

# 安装 PostgreSQL
sudo apt install -y postgresql postgresql-contrib

# 安装 Redis
sudo apt install -y redis-server

# 安装 Nginx
sudo apt install -y nginx
```

---

## 5. 数据库设计

### 5.1 数据库创建

```sql
-- 连接 PostgreSQL
sudo -u postgres psql

-- 创建数据库
CREATE DATABASE vpn_shop;
CREATE USER vpn_admin WITH ENCRYPTED PASSWORD 'your_secure_password';
GRANT ALL PRIVILEGES ON DATABASE vpn_shop TO vpn_admin;

-- 退出
\q
```

### 5.2 表结构设计

```sql
-- ===============================================
-- 用户表
-- ===============================================
CREATE TABLE customers (
    id              SERIAL PRIMARY KEY,
    email           VARCHAR(255) UNIQUE NOT NULL,
    email_type      VARCHAR(20) NOT NULL,          -- 'qq' / 'google'
    password_hash   VARCHAR(255),                   -- 留空表示仅第三方登录
    status          SMALLINT DEFAULT 1,             -- 1=正常 0=禁用
    email_verified  BOOLEAN DEFAULT FALSE,          -- 邮箱是否验证
    verify_code     VARCHAR(10),                   -- 验证码
    verify_expire   TIMESTAMP,                     -- 验证码过期时间
    last_login_at   TIMESTAMP,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_customers_email ON customers(email);
CREATE INDEX idx_customers_status ON customers(status);


-- ===============================================
-- 套餐表
-- ===============================================
CREATE TABLE plans (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,          -- 套餐名称
    description     TEXT,                           -- 套餐描述
    price           DECIMAL(10,2) NOT NULL,         -- 价格(元)
    original_price  DECIMAL(10,2),                  -- 原价(用于显示折扣)
    duration_days   INTEGER NOT NULL,               -- 时长(天)
    traffic_gb      BIGINT DEFAULT 0,               -- 流量限制(GB, 0=不限)
    device_limit    INTEGER DEFAULT 1,              -- 设备限制
    speed_limit_mbps INTEGER DEFAULT 0,             -- 速度限制(Mbps, 0=不限)
    protocol_type   VARCHAR(50) DEFAULT 'vless',   -- 协议类型
    sort_order      INTEGER DEFAULT 0,              -- 排序
    status          SMALLINT DEFAULT 1,             -- 1=上架 0=下架
    is_recommended  BOOLEAN DEFAULT FALSE,          -- 是否推荐
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_plans_status ON plans(status);


-- ===============================================
-- 订单表
-- ===============================================
CREATE TABLE orders (
    id              SERIAL PRIMARY KEY,
    order_no        VARCHAR(64) UNIQUE NOT NULL,   -- 订单号
    customer_id     INTEGER NOT NULL REFERENCES customers(id),
    plan_id         INTEGER NOT NULL REFERENCES plans(id),
    quantity        INTEGER DEFAULT 1,              -- 购买数量
    amount          DECIMAL(10,2) NOT NULL,        -- 实付金额
    discount_amount DECIMAL(10,2) DEFAULT 0,        -- 优惠金额
    payment_method  VARCHAR(30),                    -- stripe/alipay/wxpay
    payment_status  SMALLINT DEFAULT 0,             -- 0=待支付 1=已支付 2=已退款 3=已取消
    transaction_id  VARCHAR(128),                   -- 支付平台订单号
    paid_at         TIMESTAMP,                      -- 支付时间
    expire_at       TIMESTAMP,                      -- 订单过期时间(待支付时)
    remark          TEXT,                           -- 备注
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_status ON orders(payment_status);
CREATE INDEX idx_orders_no ON orders(order_no);


-- ===============================================
-- 订阅表
-- ===============================================
CREATE TABLE subscriptions (
    id              SERIAL PRIMARY KEY,
    customer_id     INTEGER NOT NULL REFERENCES customers(id),
    order_id        INTEGER REFERENCES orders(id),
    plan_id         INTEGER NOT NULL REFERENCES plans(id),
    client_uuid     VARCHAR(64),                    -- X-UI Client UUID
    client_email    VARCHAR(255),                   -- X-UI Client Email
    inbound_id      INTEGER,                        -- 关联的 Inbound ID
    start_at        BIGINT NOT NULL,                -- 开始时间戳(毫秒)
    expire_at       BIGINT NOT NULL,                -- 到期时间戳(毫秒)
    traffic_limit   BIGINT,                         -- 流量限制(字节)
    traffic_used    BIGINT DEFAULT 0,               -- 已用流量(字节)
    device_limit    INTEGER,                        -- 设备限制
    status          SMALLINT DEFAULT 1,             -- 1=生效 0=已过期
    auto_renew      BOOLEAN DEFAULT FALSE,         -- 自动续费
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_subs_customer ON subscriptions(customer_id);
CREATE INDEX idx_subs_expire ON subscriptions(expire_at);
CREATE INDEX idx_subs_uuid ON subscriptions(client_uuid);


-- ===============================================
-- 支付回调记录表
-- ===============================================
CREATE TABLE payment_callbacks (
    id              SERIAL PRIMARY KEY,
    order_no        VARCHAR(64),
    payment_method  VARCHAR(30),
    callback_data   TEXT,                           -- 原始回调数据(JSON)
    sign_data       TEXT,                           -- 签名原数据
    status          SMALLINT DEFAULT 0,             -- 0=待处理 1=已处理 2=处理失败
    error_msg       TEXT,                           -- 错误信息
    processed_at    TIMESTAMP,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_callbacks_order ON payment_callbacks(order_no);


-- ===============================================
-- 操作日志表
-- ===============================================
CREATE TABLE operation_logs (
    id              SERIAL PRIMARY KEY,
    customer_id     INTEGER REFERENCES customers(id),
    action          VARCHAR(50),                    -- register/login/purchase/renew
    ip_address      VARCHAR(45),
    user_agent      TEXT,
    detail          JSONB,                         -- 详细信息
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_logs_customer ON operation_logs(customer_id);
CREATE INDEX idx_logs_action ON operation_logs(action);
CREATE INDEX idx_logs_created ON operation_logs(created_at);


-- ===============================================
-- 系统配置表
-- ===============================================
CREATE TABLE system_configs (
    id              SERIAL PRIMARY KEY,
    config_key      VARCHAR(100) UNIQUE NOT NULL,
    config_value    TEXT,
    description     VARCHAR(255),
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 初始配置
INSERT INTO system_configs (config_key, config_value, description) VALUES
('xui_api_url', 'http://127.0.0.1:2053', '3X-UI API 地址'),
('xui_api_token', '', '3X-UI API Token'),
('xui_inbound_id', '1', '默认 Inbound ID'),
('payment_hupijiao_appid', '', '虎皮椒 AppID'),
('payment_hupijiao_appkey', '', '虎皮椒 AppKey'),
('payment_hupijiao_notify_url', 'https://your-domain.com/api/callback/hupijiao', '回调地址'),
('email_smtp_host', '', 'SMTP 服务器'),
('email_smtp_port', '587', 'SMTP 端口'),
('email_username', '', '邮箱用户名'),
('email_password', '', '邮箱密码'),
('site_name', 'VPN Store', '网站名称'),
('site_url', 'https://your-domain.com', '网站地址');
```

---

## 6. 3X-UI 配置

### 6.1 安装 3X-UI

```bash
# 下载安装
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# 安装过程中选择:
# - 语言: 中文
# - 端口: 2053
# - 用户名: admin
# - 密码: 设置强密码
```

### 6.2 配置 API Token

1. 登录 3X-UI 后台 (http://your-domain:2053)
2. 进入 **设置** → **面板设置**
3. 找到 **API Token** 选项
4. 点击生成或手动输入一个随机字符串
5. 保存设置

**重要**: 记录这个 Token，后面配置商业网站需要用到

### 6.3 创建 Inbound 节点

1. 进入 **入界列表**
2. 点击 **添加入界**
3. 配置示例 (VLESS + WebSocket + TLS):

```json
{
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "security": "tls",
    "tlsSettings": {
      "certificates": [],
      "serverName": "your-domain.com"
    },
    "wsSettings": {
      "path": "/vless",
      "headers": {}
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}
```

4. 保存并启用

### 6.4 开启订阅功能

1. 进入 **设置** → **订阅设置**
2. 启用订阅
3. 配置订阅端口 (默认 2096)
4. 保存

---

## 7. 后端开发

### 7.1 项目结构

```
vpn-shop/
├── cmd/
│   └── server/
│       └── main.go           # 入口文件
├── internal/
│   ├── config/
│   │   └── config.go         # 配置加载
│   ├── controller/
│   │   ├── auth.go          # 认证控制器
│   │   ├── plan.go          # 套餐控制器
│   │   ├── order.go         # 订单控制器
│   │   └── callback.go      # 支付回调控制器
│   ├── service/
│   │   ├── auth.go          # 认证服务
│   │   ├── plan.go          # 套餐服务
│   │   ├── order.go         # 订单服务
│   │   ├── subscription.go   # 订阅服务
│   │   ├── xui.go           # 3X-UI API 服务
│   │   └── email.go         # 邮件服务
│   ├── model/
│   │   ├── customer.go      # 用户模型
│   │   ├── plan.go          # 套餐模型
│   │   ├── order.go         # 订单模型
│   │   └── subscription.go  # 订阅模型
│   ├── repository/
│   │   ├── customer.go      # 用户数据层
│   │   ├── plan.go          # 套餐数据层
│   │   ├── order.go         # 订单数据层
│   │   └── subscription.go  # 订阅数据层
│   ├── middleware/
│   │   ├── auth.go          # 认证中间件
│   │   ├── cors.go          # 跨域中间件
│   │   └── ratelimit.go     # 限流中间件
│   ├── router/
│   │   └── router.go        # 路由配置
│   └── utils/
│       ├── response.go      # 响应工具
│       ├── hash.go          # 加密工具
│       └── validator.go     # 验证工具
├── pkg/
│   └── xui/
│       └── client.go        # 3X-UI API 客户端
├── migrations/              # 数据库迁移
├── config.yaml             # 配置文件
├── go.mod
└── go.sum
```

### 7.2 核心代码 - 3X-UI API 客户端

```go
// pkg/xui/client.go
package xui

import (
    "bytes"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "time"
)

type Client struct {
    BaseURL    string
    APIToken   string
    HTTPClient *http.Client
}

type ClientInfo struct {
    ID         int64   `json:"id,omitempty"`          // Inbound ID
    Email      string  `json:"email"`                  // 客户端邮箱
    UUID       string  `json:"uuid"`                   // 客户端 UUID
    TotalGB    float64 `json:"totalGB"`                // 流量限制(GB)
    ExpiryTime int64   `json:"expiryTime"`             // 过期时间(毫秒)
    LimitIP    int     `json:"limitIp"`                // IP 限制
    Enable     bool    `json:"enable"`                 // 是否启用
}

type APIResponse struct {
    Success bool        `json:"success"`
    Msg     string      `json:"msg"`
    Obj     interface{} `json:"obj"`
}

func NewClient(baseURL, apiToken string) *Client {
    return &Client{
        BaseURL:  baseURL,
        APIToken: apiToken,
        HTTPClient: &http.Client{
            Timeout: 30 * time.Second,
        },
    }
}

func (c *Client) doRequest(method, path string, body interface{}) (*APIResponse, error) {
    var reqBody io.Reader
    if body != nil {
        jsonData, err := json.Marshal(body)
        if err != nil {
            return nil, err
        }
        reqBody = bytes.NewBuffer(jsonData)
    }

    req, err := http.NewRequest(method, c.BaseURL+path, reqBody)
    if err != nil {
        return nil, err
    }

    req.Header.Set("Authorization", "Bearer "+c.APIToken)
    req.Header.Set("Content-Type", "application/json")

    resp, err := c.HTTPClient.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    var result APIResponse
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, err
    }

    return &result, nil
}

// AddClient 添加客户端到指定 Inbound
func (c *Client) AddClient(client *ClientInfo) error {
    resp, err := c.doRequest("POST", "/panel/api/inbounds/addClient", client)
    if err != nil {
        return err
    }
    if !resp.Success {
        return fmt.Errorf("添加客户端失败: %s", resp.Msg)
    }
    return nil
}

// UpdateClient 更新客户端信息
func (c *Client) UpdateClient(clientUUID string, updates map[string]interface{}) error {
    updates["uuid"] = clientUUID
    resp, err := c.doRequest("POST", "/panel/api/inbounds/updateClient", updates)
    if err != nil {
        return err
    }
    if !resp.Success {
        return fmt.Errorf("更新客户端失败: %s", resp.Msg)
    }
    return nil
}

// DeleteClient 删除客户端
func (c *Client) DeleteClient(inboundID int64, clientUUID string) error {
    resp, err := c.doRequest("POST",
        fmt.Sprintf("/panel/api/inbounds/%d/delClient/%s", inboundID, clientUUID),
        nil)
    if err != nil {
        return err
    }
    if !resp.Success {
        return fmt.Errorf("删除客户端失败: %s", resp.Msg)
    }
    return nil
}

// GetSubLink 获取订阅链接
func (c *Client) GetSubLink(subID string) (string, error) {
    resp, err := c.doRequest("GET", fmt.Sprintf("/panel/api/inbounds/getSubLinks/%s", subID), nil)
    if err != nil {
        return "", err
    }
    if !resp.Success {
        return "", fmt.Errorf("获取订阅链接失败: %s", resp.Msg)
    }
    // 订阅链接在响应中
    if link, ok := resp.Obj.(string); ok {
        return link, nil
    }
    return "", nil
}

// RestartXray 重启 Xray 服务
func (c *Client) RestartXray() error {
    resp, err := c.doRequest("POST", "/panel/api/server/restartXray", nil)
    if err != nil {
        return err
    }
    if !resp.Success {
        return fmt.Errorf("重启Xray失败: %s", resp.Msg)
    }
    return nil
}
```

### 7.3 核心代码 - 自动开通服务

```go
// internal/service/subscription.go
package service

import (
    "fmt"
    "log"
    "time"

    "vpn-shop/internal/model"
    "vpn-shop/pkg/xui"

    "github.com/google/uuid"
    "gorm.io/gorm"
)

type SubscriptionService struct {
    db     *gorm.DB
    xuiClient *xui.Client
}

func NewSubscriptionService(db *gorm.DB, xuiClient *xui.Client) *SubscriptionService {
    return &SubscriptionService{
        db:     db,
        xuiClient: xuiClient,
    }
}

// ActivateSubscription 激活订阅 - 支付成功后的核心逻辑
func (s *SubscriptionService) ActivateSubscription(order *model.Order) (*model.Subscription, error) {
    // 1. 获取套餐信息
    var plan model.Plan
    if err := s.db.First(&plan, order.PlanID).Error; err != nil {
        return nil, fmt.Errorf("获取套餐失败: %w", err)
    }

    // 2. 获取客户信息
    var customer model.Customer
    if err := s.db.First(&customer, order.CustomerID).Error; err != nil {
        return nil, fmt.Errorf("获取客户失败: %w", err)
    }

    // 3. 检查是否已有生效的订阅
    var existingSub model.Subscription
    hasExisting := s.db.Where("customer_id = ? AND status = 1", customer.ID).
        First(&existingSub).Error == nil

    var clientUUID string
    var clientEmail string
    var startAt, expireAt int64

    if hasExisting {
        // 续费：延长到期时间
        clientUUID = existingSub.ClientUUID
        clientEmail = existingSub.ClientEmail
        startAt = existingSub.StartAt
        expireAt = existingSub.ExpireAt + int64(plan.DurationDays)*24*60*60*1000

        // 更新 X-UI 中的过期时间
        err := s.xuiClient.UpdateClient(clientUUID, map[string]interface{}{
            "id":         existingSub.InboundID,
            "expiryTime": expireAt,
        })
        if err != nil {
            log.Printf("更新X-UI客户端过期时间失败: %v", err)
        }
    } else {
        // 新订阅：创建新客户端
        clientUUID = uuid.New().String()
        clientEmail = customer.Email
        startAt = time.Now().Unix() * 1000
        expireAt = startAt + int64(plan.DurationDays)*24*60*60*1000

        // 转换流量限制 (GB -> 字节)
        trafficBytes := plan.TrafficGB * 1024 * 1024 * 1024
        if plan.TrafficGB == 0 {
            trafficBytes = 0 // 不限流量
        }

        // 调用 3X-UI API 添加客户端
        xuiClient := &xui.ClientInfo{
            ID:         1, // Inbound ID，从配置获取
            Email:      clientEmail,
            UUID:       clientUUID,
            TotalGB:    float64(plan.TrafficGB),
            ExpiryTime: expireAt,
            LimitIP:    plan.DeviceLimit,
            Enable:     true,
        }

        err := s.xuiClient.AddClient(xuiClient)
        if err != nil {
            return nil, fmt.Errorf("添加X-UI客户端失败: %w", err)
        }
    }

    // 4. 创建/更新订阅记录
    subscription := &model.Subscription{
        CustomerID:   customer.ID,
        OrderID:      &order.ID,
        PlanID:       plan.ID,
        ClientUUID:   clientUUID,
        ClientEmail:  clientEmail,
        InboundID:    1, // 从配置获取
        StartAt:      startAt,
        ExpireAt:     expireAt,
        TrafficLimit: plan.TrafficGB * 1024 * 1024 * 1024,
        DeviceLimit:  plan.DeviceLimit,
        Status:       1,
    }

    if hasExisting {
        subscription.ID = existingSub.ID
        subscription.TrafficUsed = existingSub.TrafficUsed
        if err := s.db.Save(subscription).Error; err != nil {
            return nil, fmt.Errorf("更新订阅失败: %w", err)
        }
    } else {
        if err := s.db.Create(subscription).Error; err != nil {
            return nil, fmt.Errorf("创建订阅失败: %w", err)
        }
    }

    // 5. 重启 Xray 使配置生效
    if !hasExisting {
        if err := s.xuiClient.RestartXray(); err != nil {
            log.Printf("重启Xray失败: %v", err)
            // 不返回错误，因为客户端已添加成功
        }
    }

    log.Printf("订阅激活成功: customer=%s, plan=%s, expire=%s",
        customer.Email, plan.Name, time.Unix(expireAt/1000, 0).Format("2006-01-02"))

    return subscription, nil
}

// GetSubscription 获取客户当前订阅
func (s *SubscriptionService) GetActiveSubscription(customerID uint) (*model.Subscription, error) {
    var sub model.Subscription
    err := s.db.Where("customer_id = ? AND status = 1", customerID).
        Order("expire_at DESC").
        First(&sub).Error
    if err != nil {
        return nil, err
    }
    return &sub, nil
}

// CheckExpiredSubscriptions 检查过期订阅并更新状态
func (s *SubscriptionService) CheckExpiredSubscriptions() error {
    now := time.Now().Unix() * 1000
    return s.db.Model(&model.Subscription{}).
        Where("status = 1 AND expire_at < ?", now).
        Update("status", 0).Error
}
```

### 7.4 核心代码 - 支付回调处理

```go
// internal/controller/callback.go
package controller

import (
    "crypto/md5"
    "fmt"
    "io"
    "net/http"
    "sort"
    "strings"
    "time"

    "vpn-shop/internal/model"
    "vpn-shop/internal/service"

    "github.com/gin-gonic/gin"
    "gorm.io/gorm"
)

type CallbackController struct {
    db                *gorm.DB
    subscriptionSvc   *service.SubscriptionService
    orderSvc          *service.OrderService
    emailSvc          *service.EmailService
    hupijiaoAppID     string
    hupijiaoAppKey    string
    notifyURL         string
}

func NewCallbackController(
    db *gorm.DB,
    subscriptionSvc *service.SubscriptionService,
    orderSvc *service.OrderService,
    emailSvc *service.EmailService,
    appID, appKey, notifyURL string,
) *CallbackController {
    return &CallbackController{
        db:              db,
        subscriptionSvc: subscriptionSvc,
        orderSvc:        orderSvc,
        emailSvc:        emailSvc,
        hupijiaoAppID:   appID,
        hupijiaoAppKey:  appKey,
        notifyURL:       notifyURL,
    }
}

// HupijiaoCallback 虎皮椒支付回调
func (c *CallbackController) HupijiaoCallback(ctx *gin.Context) {
    // 1. 获取回调参数
    orderNo := ctx.PostForm("order_no")
    tradeStatus := ctx.PostForm("trade_status")
    totalFee := ctx.PostForm("total_fee")
    tradeNo := ctx.PostForm("trade_no")
    param := ctx.PostForm("param")

    // 2. 记录回调日志
    callbackLog := &model.PaymentCallback{
        OrderNo:       orderNo,
        PaymentMethod: "hupijiao",
        CallbackData:  fmt.Sprintf("trade_status=%s,total_fee=%s,trade_no=%s,param=%s",
            tradeStatus, totalFee, tradeNo, param),
        Status: 0,
    }
    c.db.Create(callbackLog)

    // 3. 验证签名
    sign := ctx.PostForm("sign")
    if !c.verifyHupijiaoSign(ctx.Request.PostForm, sign) {
        callbackLog.Status = 2
        callbackLog.ErrorMsg = "签名验证失败"
        c.db.Save(callbackLog)
        ctx.String(http.StatusBadRequest, "fail")
        return
    }

    // 4. 检查订单是否存在
    var order model.Order
    if err := c.db.Where("order_no = ?", orderNo).First(&order).Error; err != nil {
        callbackLog.Status = 2
        callbackLog.ErrorMsg = "订单不存在"
        c.db.Save(callbackLog)
        ctx.String(http.StatusOK, "fail")
        return
    }

    // 5. 检查订单状态，防止重复处理
    if order.PaymentStatus != 0 {
        callbackLog.Status = 1
        callbackLog.ProcessedAt = timePtr(time.Now())
        c.db.Save(callbackLog)
        ctx.String(http.StatusOK, "success") // 返回success避免重复回调
        return
    }

    // 6. 处理支付成功
    if tradeStatus == "OD" || tradeStatus == "TRADE_SUCCESS" {
        if err := c.processPaymentSuccess(&order, tradeNo); err != nil {
            callbackLog.Status = 2
            callbackLog.ErrorMsg = err.Error()
            c.db.Save(callbackLog)
            ctx.String(http.StatusInternalServerError, "fail")
            return
        }
    }

    // 7. 更新回调记录
    callbackLog.Status = 1
    callbackLog.ProcessedAt = timePtr(time.Now())
    c.db.Save(callbackLog)

    ctx.String(http.StatusOK, "success")
}

// verifyHupijiaoSign 验证虎皮椒签名
func (c *CallbackController) verifyHupijiaoSign(form map[string][]string, sign string) bool {
    // 排除 sign 字段，构建签名数据
    var keys []string
    var values []string
    for k, v := range form {
        if k == "sign" || k == "sign_type" {
            continue
        }
        keys = append(keys, k)
        values = append(values, v[0])
    }

    // 按字典序排序
    sort.Strings(keys)

    // 拼接字符串
    var signStr strings.Builder
    for _, k := range keys {
        signStr.WriteString(k + "=" + getFirstValue(form, k) + "&")
    }
    signStr.WriteString("key=" + c.hupijiaoAppKey)

    // 计算 MD5
    expectedSign := fmt.Sprintf("%x", md5.Sum([]byte(signStr.String())))
    return strings.ToLower(sign) == expectedSign
}

func getFirstValue(m map[string][]string, k string) string {
    if v, ok := m[k]; ok && len(v) > 0 {
        return v[0]
    }
    return ""
}

func timePtr(t time.Time) *time.Time {
    return &t
}

// processPaymentSuccess 处理支付成功
func (c *CallbackController) processPaymentSuccess(order *model.Order, transactionID string) error {
    // 1. 更新订单状态
    order.PaymentStatus = 1
    order.TransactionID = transactionID
    now := time.Now()
    order.PaidAt = &now
    if err := c.db.Save(order).Error; err != nil {
        return err
    }

    // 2. 激活订阅
    subscription, err := c.subscriptionSvc.ActivateSubscription(order)
    if err != nil {
        return err
    }

    // 3. 获取客户信息用于发送邮件
    var customer model.Customer
    if err := c.db.First(&customer, order.CustomerID).Error; err != nil {
        return err
    }

    // 4. 发送通知邮件
    go func() {
        if err := c.emailSvc.SendSubscriptionActivated(&customer, subscription); err != nil {
            // 记录错误但不阻塞流程
            fmt.Printf("发送订阅激活邮件失败: %v\n", err)
        }
    }()

    return nil
}
```

### 7.5 核心代码 - 邮件服务

```go
// internal/service/email.go
package service

import (
    "fmt"
    "html/template"
    "net/smtp"

    "vpn-shop/internal/model"
)

type EmailService struct {
    smtpHost     string
    smtpPort     string
    username     string
    password     string
    fromAddress  string
}

func NewEmailService(host, port, username, password, fromAddress string) *EmailService {
    return &EmailService{
        smtpHost:    host,
        smtpPort:    port,
        username:    username,
        password:    password,
        fromAddress: fromAddress,
    }
}

// SendSubscriptionActivated 发送订阅激活通知
func (s *EmailService) SendSubscriptionActivated(customer *model.Customer, sub *model.Subscription) error {
    subject := "VPN订阅开通成功"

    html := fmt.Sprintf(`
    <html>
    <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
        <h2 style="color: #2ecc71;">🎉 恭喜！您的VPN订阅已成功开通</h2>

        <div style="background: #f9f9f9; padding: 20px; border-radius: 8px; margin: 20px 0;">
            <h3 style="margin-top: 0;">📋 订阅信息</h3>
            <table style="width: 100%%;">
                <tr>
                    <td style="padding: 8px 0;"><strong>订阅邮箱：</strong></td>
                    <td>%s</td>
                </tr>
                <tr>
                    <td style="padding: 8px 0;"><strong>节点地址：</strong></td>
                    <td>vpn.your-domain.com</td>
                </tr>
                <tr>
                    <td style="padding: 8px 0;"><strong>订阅链接：</strong></td>
                    <td><a href="https://your-domain.com/sub/%s">点击获取订阅</a></td>
                </tr>
                <tr>
                    <td style="padding: 8px 0;"><strong>到期时间：</strong></td>
                    <td>%s</td>
                </tr>
            </table>
        </div>

        <div style="background: #e8f5e9; padding: 15px; border-radius: 8px; margin: 20px 0;">
            <h3 style="margin-top: 0;">📱 使用指南</h3>
            <ol style="margin: 10px 0; padding-left: 20px;">
                <li>复制上方订阅链接</li>
                <li>打开您的VPN客户端（如 Clash、V2RayN）</li>
                <li>粘贴订阅链接并更新</li>
                <li>选择节点并连接</li>
            </ol>
        </div>

        <p style="color: #666; font-size: 14px;">
            如有问题，请回复此邮件联系我们。<br>
            祝您使用愉快！
        </p>

        <hr style="border: none; border-top: 1px solid #eee; margin: 20px 0;">
        <p style="color: #999; font-size: 12px; text-align: center;">
            © 2024 VPN Store. All rights reserved.
        </p>
    </body>
    </html>
    `,
        customer.Email,
        sub.ClientUUID,
        formatTime(sub.ExpireAt),
    )

    return s.sendEmail(customer.Email, subject, html)
}

func formatTime(timestamp int64) string {
    // 转换毫秒时间戳
    if timestamp > 1e12 {
        timestamp = timestamp / 1000
    }
    return fmt.Sprintf("%d-%02d-%02d %02d:%02d",
        timestamp/31536000+1970,
        (timestamp%31536000)/2592000,
        (timestamp%2592000)/86400,
        (timestamp%86400)/3600,
        (timestamp%3600)/60,
    )
}

func (s *EmailService) sendEmail(to, subject, htmlBody string) error {
    auth := smtp.PlainAuth("", s.username, s.password, s.smtpHost)

    headers := make(map[string]string)
    headers["From"] = s.fromAddress
    headers["To"] = to
    headers["Subject"] = subject
    headers["MIME-Version"] = "1.0"
    headers["Content-Type"] = "text/html; charset=\"utf-8\""

    var msg strings.Builder
    for k, v := range headers {
        msg.WriteString(fmt.Sprintf("%s: %s\r\n", k, v))
    }
    msg.WriteString("\r\n")
    msg.WriteString(htmlBody)

    addr := fmt.Sprintf("%s:%s", s.smtpHost, s.smtpPort)

    if s.smtpPort == "465" {
        return smtp.SendMail(addr, auth, s.username, []string{to}, []byte(msg.String()))
    }

    return smtp.SendMail(addr, auth, s.username, []string{to}, []byte(msg.String()))
}
```

---

## 8. 前端开发

### 8.1 项目创建

```bash
# 创建项目
npm create vite@latest vpn-shop-web -- --template vue-ts

# 进入目录
cd vpn-shop-web

# 安装依赖
npm install
npm install vant @vant/icons vue-router pinia axios @vueuse/core

# 启动开发服务器
npm run dev
```

### 8.2 路由配置

```typescript
// src/router/index.ts
import { createRouter, createWebHistory, RouteRecordRaw } from 'vue-router'

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'Home',
    component: () => import('@/pages/Home.vue'),
  },
  {
    path: '/login',
    name: 'Login',
    component: () => import('@/pages/Login.vue'),
  },
  {
    path: '/register',
    name: 'Register',
    component: () => import('@/pages/Register.vue'),
  },
  {
    path: '/plans',
    name: 'Plans',
    component: () => import('@/pages/Plans.vue'),
  },
  {
    path: '/checkout/:planId',
    name: 'Checkout',
    component: () => import('@/pages/Checkout.vue'),
  },
  {
    path: '/dashboard',
    name: 'Dashboard',
    component: () => import('@/pages/Dashboard.vue'),
    meta: { requiresAuth: true },
  },
  {
    path: '/orders',
    name: 'Orders',
    component: () => import('@/pages/Orders.vue'),
    meta: { requiresAuth: true },
  },
  {
    path: '/guide',
    name: 'Guide',
    component: () => import('@/pages/Guide.vue'),
  },
]

const router = createRouter({
  history: createWebHistory(),
  routes,
})

// 路由守卫
router.beforeEach((to, from, next) => {
  const token = localStorage.getItem('token')
  if (to.meta.requiresAuth && !token) {
    next('/login')
  } else {
    next()
  }
})

export default router
```

### 8.3 套餐页面

```vue
<!-- src/pages/Plans.vue -->
<template>
  <div class="plans-page">
    <van-nav-bar title="选择套餐" left-arrow @click-left="router.back()" />

    <div class="plans-container">
      <van-tabs v-model:active="activeTab" shrink>
        <van-tab title="月付" name="monthly"></van-tab>
        <van-tab title="季付" name="quarterly"></van-tab>
        <van-tab title="年付" name="yearly"></van-tab>
      </van-tabs>

      <div class="plans-list">
        <div
          v-for="plan in filteredPlans"
          :key="plan.id"
          class="plan-card"
          :class="{ recommended: plan.isRecommended }"
        >
          <div v-if="plan.isRecommended" class="recommended-tag">
            推荐
          </div>

          <h3 class="plan-name">{{ plan.name }}</h3>

          <div class="plan-price">
            <span class="currency">¥</span>
            <span class="amount">{{ plan.price }}</span>
            <span class="period">/{{ plan.durationDays }}天</span>
          </div>

          <div v-if="plan.originalPrice > plan.price" class="original-price">
            原价 ¥{{ plan.originalPrice }}
          </div>

          <van-divider />

          <ul class="plan-features">
            <li>
              <van-icon name="passed" color="#07c160" />
              {{ plan.trafficGb > 0 ? `${plan.trafficGb}GB 流量` : '不限流量' }}
            </li>
            <li>
              <van-icon name="passed" color="#07c160" />
              支持 {{ plan.deviceLimit }} 台设备
            </li>
            <li>
              <van-icon name="passed" color="#07c160" />
              {{ plan.protocolType.toUpperCase() }} 协议
            </li>
            <li v-if="plan.speedLimitMbps > 0">
              <van-icon name="passed" color="#07c160" />
              限速 {{ plan.speedLimitMbps }} Mbps
            </li>
          </ul>

          <van-button
            type="primary"
            block
            round
            :disabled="plan.status !== 1"
            @click="handlePurchase(plan)"
          >
            {{ plan.status === 1 ? '立即购买' : '暂不可用' }}
          </van-button>
        </div>
      </div>
    </div>

    <van-tabbar route>
      <van-tabbar-item to="/" icon="home-o">首页</van-tabbar-item>
      <van-tabbar-item to="/plans" icon="coupon-o">套餐</van-tabbar-item>
      <van-tabbar-item to="/dashboard" icon="user-o" :dot="hasActiveSubscription">
        我的
      </van-tabbar-item>
    </van-tabbar>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { showToast } from 'vant'
import { getPlans } from '@/api/plan'
import type { Plan } from '@/api/plan'

const router = useRouter()
const activeTab = ref('monthly')
const plans = ref<Plan[]>([])

const filteredPlans = computed(() => {
  return plans.value.filter(plan => {
    if (activeTab.value === 'monthly') return plan.durationDays <= 31
    if (activeTab.value === 'quarterly') return plan.durationDays > 31 && plan.durationDays <= 93
    if (activeTab.value === 'yearly') return plan.durationDays > 93
    return true
  })
})

const hasActiveSubscription = ref(false)

const handlePurchase = (plan: Plan) => {
  const token = localStorage.getItem('token')
  if (!token) {
    router.push('/login?redirect=/checkout/' + plan.id)
  } else {
    router.push('/checkout/' + plan.id)
  }
}

onMounted(async () => {
  try {
    const res = await getPlans()
    plans.value = res.data
  } catch (error) {
    showToast('加载套餐失败')
  }
})
</script>

<style scoped>
.plans-container {
  padding: 16px;
  padding-bottom: 80px;
}

.plans-list {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 16px;
  margin-top: 16px;
}

.plan-card {
  background: #fff;
  border-radius: 12px;
  padding: 20px;
  position: relative;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
  transition: transform 0.2s, box-shadow 0.2s;
}

.plan-card:hover {
  transform: translateY(-4px);
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.12);
}

.plan-card.recommended {
  border: 2px solid #1989fa;
}

.recommended-tag {
  position: absolute;
  top: -10px;
  left: 50%;
  transform: translateX(-50%);
  background: linear-gradient(135deg, #1989fa, #1976d2);
  color: #fff;
  padding: 4px 16px;
  border-radius: 12px;
  font-size: 12px;
  font-weight: bold;
}

.plan-name {
  text-align: center;
  font-size: 18px;
  font-weight: bold;
  margin: 8px 0;
}

.plan-price {
  text-align: center;
  margin: 16px 0;
}

.plan-price .currency {
  font-size: 16px;
  color: #ee0a24;
}

.plan-price .amount {
  font-size: 32px;
  font-weight: bold;
  color: #ee0a24;
}

.plan-price .period {
  font-size: 14px;
  color: #969799;
}

.original-price {
  text-align: center;
  color: #969799;
  text-decoration: line-through;
  font-size: 14px;
  margin-top: -12px;
}

.plan-features {
  list-style: none;
  padding: 0;
  margin: 16px 0;
}

.plan-features li {
  padding: 8px 0;
  display: flex;
  align-items: center;
  gap: 8px;
  color: #646566;
}
</style>
```

### 8.4 支付页面

```vue
<!-- src/pages/Checkout.vue -->
<template>
  <div class="checkout-page">
    <van-nav-bar title="确认订单" left-arrow @click-left="router.back()" />

    <van-pull-refresh v-model="refreshing" @refresh="loadData">
      <div class="checkout-content">
        <!-- 订单信息 -->
        <van-cell-group inset title="订单信息">
          <van-cell title="套餐名称" :value="orderInfo.planName" />
          <van-cell title="套餐时长" :value="`${orderInfo.durationDays}天`" />
          <van-cell title="流量限制" :value="orderInfo.trafficGb > 0 ? `${orderInfo.trafficGb}GB` : '不限'" />
        </van-cell-group>

        <!-- 支付方式 -->
        <van-cell-group inset title="支付方式">
          <van-radio-group v-model="selectedPayment">
            <van-cell clickable @click="selectedPayment = 'hupijiao_alipay'">
              <template #title>
                <div class="payment-option">
                  <van-icon name="alipay" color="#1677ff" size="24" />
                  <span>支付宝</span>
                </div>
              </template>
              <template #right-icon>
                <van-radio name="hupijiao_alipay" />
              </template>
            </van-cell>

            <van-cell clickable @click="selectedPayment = 'hupijiao_wxpay'">
              <template #title>
                <div class="payment-option">
                  <van-icon name="wechat" color="#07c160" size="24" />
                  <span>微信支付</span>
                </div>
              </template>
              <template #right-icon>
                <van-radio name="hupijiao_wxpay" />
              </template>
            </van-cell>
          </van-radio-group>
        </van-cell-group>

        <!-- 订单金额 -->
        <van-card :price="orderInfo.amount" :title="orderInfo.planName" centered>
          <template #num>
            <van-stepper v-model="quantity" min="1" max="10" @change="recalculateAmount" />
          </template>
        </van-card>

        <!-- 提交按钮 -->
        <div class="submit-section">
          <van-button
            type="primary"
            block
            round
            :loading="submitting"
            @click="handleSubmit"
          >
            提交订单 (¥{{ totalAmount }})
          </van-button>
        </div>
      </div>
    </van-pull-refresh>

    <!-- 支付二维码弹窗 -->
    <van-overlay :show="showQRCode" @click="showQRCode = false">
      <div class="qrcode-modal" @click.stop>
        <van-icon name="cross" class="close-btn" @click="showQRCode = false" />
        <h3>请使用{{ selectedPayment.includes('alipay') ? '支付宝' : '微信' }}扫码支付</h3>
        <van-loading v-if="qrLoading" type="spinner" />
        <img v-else :src="qrCodeUrl" alt="支付二维码" class="qrcode" />
        <p class="amount">¥{{ totalAmount }}</p>
        <p class="tip">请在15分钟内完成支付</p>

        <van-button type="default" block @click="checkPaymentStatus">
          我已支付
        </van-button>
      </div>
    </van-overlay>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { showToast, showSuccessToast, showFailToast } from 'vant'
import { getPlanDetail, createOrder, getPaymentQR, checkOrderStatus } from '@/api/order'

const route = useRoute()
const router = useRouter()

const refreshing = ref(false)
const submitting = ref(false)
const orderInfo = ref<any>({
  planName: '',
  price: 0,
  durationDays: 0,
  trafficGb: 0,
})
const quantity = ref(1)
const selectedPayment = ref('hupijiao_alipay')
const showQRCode = ref(false)
const qrLoading = ref(false)
const qrCodeUrl = ref('')
const currentOrderNo = ref('')
let pollingTimer: number | null = null

const totalAmount = computed(() => {
  return (orderInfo.value.price * quantity.value).toFixed(2)
})

const recalculateAmount = () => {
  // 可以在这里添加额外逻辑
}

const loadData = async () => {
  try {
    const planId = route.params.planId
    const res = await getPlanDetail(planId as string)
    orderInfo.value = res.data
  } catch (error) {
    showToast('加载失败')
  } finally {
    refreshing.value = false
  }
}

const handleSubmit = async () => {
  submitting.value = true

  try {
    // 1. 创建订单
    const orderRes = await createOrder({
      planId: orderInfo.value.id,
      quantity: quantity.value,
      paymentMethod: selectedPayment.value,
    })

    currentOrderNo.value = orderRes.data.orderNo

    // 2. 获取支付二维码
    qrLoading.value = true
    showQRCode.value = true

    const qrRes = await getPaymentQR({
      orderNo: currentOrderNo.value,
      paymentMethod: selectedPayment.value,
    })

    qrCodeUrl.value = qrRes.data.qrCodeUrl

    // 3. 开始轮询支付状态
    startPolling()
  } catch (error: any) {
    showFailToast(error.message || '创建订单失败')
  } finally {
    submitting.value = false
    qrLoading.value = false
  }
}

const startPolling = () => {
  if (pollingTimer) {
    clearInterval(pollingTimer)
  }

  pollingTimer = window.setInterval(async () => {
    try {
      const res = await checkOrderStatus(currentOrderNo.value)

      if (res.data.status === 1) {
        // 支付成功
        stopPolling()
        showQRCode.value = false
        showSuccessToast('支付成功！')

        // 跳转到订阅页面
        setTimeout(() => {
          router.replace('/dashboard')
        }, 1500)
      }
    } catch (error) {
      // 忽略轮询错误
    }
  }, 3000) // 每3秒检查一次
}

const stopPolling = () => {
  if (pollingTimer) {
    clearInterval(pollingTimer)
    pollingTimer = null
  }
}

const checkPaymentStatus = () => {
  // 手动触发检查
}

onMounted(() => {
  loadData()
})

onUnmounted(() => {
  stopPolling()
})
</script>

<style scoped>
.checkout-content {
  padding: 16px;
  padding-bottom: 100px;
}

.payment-option {
  display: flex;
  align-items: center;
  gap: 12px;
}

.submit-section {
  position: fixed;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 16px;
  background: #fff;
  box-shadow: 0 -2px 8px rgba(0, 0, 0, 0.08);
}

.qrcode-modal {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  background: #fff;
  border-radius: 12px;
  padding: 24px;
  text-align: center;
  width: 300px;
}

.close-btn {
  position: absolute;
  top: 12px;
  right: 12px;
  font-size: 20px;
  color: #969799;
}

.qrcode {
  width: 200px;
  height: 200px;
  margin: 16px 0;
}

.amount {
  font-size: 24px;
  font-weight: bold;
  color: #ee0a24;
  margin: 8px 0;
}

.tip {
  color: #969799;
  font-size: 14px;
  margin-bottom: 16px;
}
</style>
```

---

## 9. 支付对接

### 9.1 虎皮椒支付接入

#### 9.1.1 注册虎皮椒

1. 访问 [虎皮椒官网](https://admin.xunhupay.com)
2. 注册账户并完成实名认证
3. 创建应用获取 AppID 和 AppKey

#### 9.1.2 发起支付

```go
// internal/service/payment.go
package service

import (
    "crypto/md5"
    "fmt"
    "io"
    "net/http"
    "net/url"
    "sort"
    "strings"
    "time"
)

type HupijiaoService struct {
    appID    string
    appKey   string
    notifyURL string
}

func NewHupijiaoService(appID, appKey, notifyURL string) *HupijiaoService {
    return &HupijiaoService{
        appID:    appID,
        appKey:   appKey,
        notifyURL: notifyURL,
    }
}

// PaymentRequest 发起支付请求
type PaymentRequest struct {
    OrderNo    string
    Amount     float64
    PaymentMethod string // alipay / wxpay
    Subject    string
}

// PaymentResponse 支付响应
type PaymentResponse struct {
    Code    int    `json:"code"`
    Url     string `json:"url"`
    ErrMsg  string `json:"errMsg"`
    QrCode  string `json:"qrcode"`
}

func (s *HupijiaoService) CreatePayment(req *PaymentRequest) (*PaymentResponse, error) {
    // 支付接口地址 (沙箱/正式)
    payURL := "https://api.xunhupay.com/payment/do.html"

    // 构建请求参数
    params := url.Values{}
    params.Set("version", "1.1")
    params.Set("appid", s.appID)
    params.Set("trade_order_id", req.OrderNo)
    params.Set("total_fee", fmt.Sprintf("%.2f", req.Amount))
    params.Set("title", req.Subject)
    params.Set("type", req.PaymentMethod) // alipay / wxpay

    // 异步回调地址
    params.Set("notify_url", s.notifyURL)
    // 同步跳转地址 (用户支付后跳转)
    params.Set("return_url", s.notifyURL+"/return")

    // 生成签名
    sign := s.generateSign(params)
    params.Set("sign", sign)
    params.Set("sign_type", "MD5")

    // 发送请求
    resp, err := http.PostForm(payURL, params)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    body, _ := io.ReadAll(resp.Body)

    // 解析响应
    // 实际响应是 HTML 或 JSON，根据虎皮椒文档处理
    // 这里简化处理
    result := &PaymentResponse{}

    // 如果返回的是 HTML 表单，需要提取 qrcode
    if strings.Contains(string(body), "qrcode") {
        // 从响应中提取二维码链接
        // 具体实现根据虎皮椒实际返回格式
    }

    result.Code = 0
    result.QrCode = "data:image/png;base64,..." // 二维码数据

    return result, nil
}

func (s *HupijiaoService) generateSign(params url.Values) string {
    // 排除 sign 和 sign_type
    var keys []string
    for k := range params {
        if k == "sign" || k == "sign_type" {
            continue
        }
        keys = append(keys, k)
    }

    // 字典序排序
    sort.Strings(keys)

    // 拼接签名字符串
    var signStr strings.Builder
    for _, k := range keys {
        signStr.WriteString(k + "=" + params.Get(k) + "&")
    }
    signStr.WriteString("key=" + s.appKey)

    // MD5
    hash := md5.Sum([]byte(signStr.String()))
    return fmt.Sprintf("%x", hash)
}
```

### 9.2 Stripe 支付接入 (可选)

```go
// pkg/stripe/client.go
package stripe

import (
    "github.com/stripe/stripe-go/v76"
    "github.com/stripe/stripe-go/v76/checkout/session"
)

type StripeClient struct {
    secretKey string
}

func NewStripeClient(secretKey string) *StripeClient {
    stripe.Key = secretKey
    return &StripeClient{
        secretKey: secretKey,
    }
}

func (c *StripeClient) CreateCheckoutSession(params *CheckoutParams) (string, error) {
    stripeParams := &stripe.CheckoutSessionParams{
        LineItems: []*stripe.CheckoutSessionLineItemParams{
            {
                PriceData: &stripe.CheckoutSessionLineItemPriceDataParams{
                    Currency: stripe.String("cny"),
                    ProductData: &stripe.CheckoutSessionLineItemPriceDataProductDataParams{
                        Name: stripe.String(params.ProductName),
                    },
                    UnitAmount: stripe.Int64(int64(params.Amount * 100)), // 分为单位
                },
                Quantity: stripe.Int64(int64(params.Quantity)),
            },
        },
        Mode: stripe.String(string(stripe.CheckoutSessionModePayment)),
        SuccessURL: stripe.String(params.SuccessURL),
        CancelURL:  stripe.String(params.CancelURL),
        Metadata: map[string]string{
            "order_no": params.OrderNo,
        },
    }

    s, err := session.New(stripeParams)
    if err != nil {
        return "", err
    }

    return s.URL, nil
}
```

---

## 10. 自动开通逻辑

### 10.1 完整流程图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          支付回调自动开通流程                              │
└─────────────────────────────────────────────────────────────────────────┘

                        支付平台回调请求
                              │
                              ▼
                    ┌─────────────────┐
                    │  1. 签名验证    │
                    │  2. 订单查询    │
                    │  3. 状态检查    │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  4. 获取套餐    │
                    │  5. 获取客户    │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  6. 检查订阅    │
                    │  - 新订阅？    │
                    │  - 续费？      │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                              │
              ▼                              ▼
    ┌─────────────────┐            ┌─────────────────┐
    │    新订阅       │            │    续费         │
    │ - 生成UUID      │            │ - 获取原订阅   │
    │ - 生成邮箱      │            │ - 延长时间     │
    │ - 设置过期时间  │            │ - 更新配置     │
    │ - 限流限设备   │            │              │
    └────────┬────────┘            └────────┬────────┘
             │                              │
             └──────────────┬───────────────┘
                            │
                   ┌────────▼────────┐
                   │  调用3X-UI API │
                   │  添加客户端    │
                   └────────┬────────┘
                            │
                   ┌────────▼────────┐
                   │  重启Xray      │
                   │  配置生效      │
                   └────────┬────────┘
                            │
                   ┌────────▼────────┐
                   │  创建订阅记录   │
                   │  保存到数据库   │
                   └────────┬────────┘
                            │
                   ┌────────▼────────┐
                   │  发送通知邮件  │
                   │  包含订阅链接  │
                   └────────┬────────┘
                            │
                            ▼
                    ┌─────────────────┐
                    │    完成         │
                    │  返回success   │
                    └─────────────────┘
```

### 10.2 定时任务

```go
// internal/service/cron.go
package service

import (
    "log"
    "time"
)

// StartCronJobs 启动定时任务
func StartCronJobs(subscriptionSvc *SubscriptionService, emailSvc *EmailService) {
    // 每分钟检查过期订阅
    go func() {
        ticker := time.NewTicker(1 * time.Minute)
        for range ticker.C {
            if err := subscriptionSvc.CheckExpiredSubscriptions(); err != nil {
                log.Printf("检查过期订阅失败: %v", err)
            }
        }
    }()

    // 每天早上9点发送到期提醒
    go func() {
        for {
            now := time.Now()
            // 计算下一个9点
            next := time.Date(now.Year(), now.Month(), now.Day(), 9, 0, 0, 0, now.Location())
            if next.Before(now) {
                next = next.Add(24 * time.Hour)
            }
            <-time.After(time.Until(next))

            // 发送到期提醒
            sendExpiryReminders(subscriptionSvc, emailSvc)
        }
    }()
}

func sendExpiryReminders(subscriptionSvc *SubscriptionService, emailSvc *EmailService) {
    // 查找3天内即将过期的订阅
    subs, err := subscriptionSvc.GetExpiringSoon(3)
    if err != nil {
        log.Printf("查询即将过期订阅失败: %v", err)
        return
    }

    for _, sub := range subs {
        if err := emailSvc.SendExpiryReminder(sub); err != nil {
            log.Printf("发送到期提醒失败: customer=%s, err=%v", sub.CustomerEmail, err)
        }
    }
}
```

---

## 11. 部署指南

### 11.1 服务器部署结构

```
/var/www/vpn-shop/
├── frontend/              # 前端构建产物
│   └── dist/
├── backend/               # 后端二进制
│   └── vpn-shop
├── config.yaml            # 配置文件
└── logs/                  # 日志目录

/etc/nginx/sites-available/vpn-shop
```

### 11.2 Nginx 配置

```nginx
server {
    listen 80;
    server_name your-domain.com;

    # 强制跳转到 HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    # SSL 证书
    ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # 前端静态文件
    root /var/www/vpn-shop/frontend/dist;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # API 代理
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 3X-UI 面板 (可选暴露)
    location /panel/ {
        proxy_pass http://127.0.0.1:2053;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # 订阅服务代理
    location /sub/ {
        proxy_pass http://127.0.0.1:2096;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }

    # 静态资源缓存
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
```

### 11.3 Systemd 服务配置

```ini
# /etc/systemd/system/vpn-shop.service
[Unit]
Description=VPN Shop Backend Service
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/vpn-shop/backend
ExecStart=/var/www/vpn-shop/backend/vpn-shop
Restart=always
RestartSec=5
StandardOutput=append:/var/www/vpn-shop/logs/stdout.log
StandardError=append:/var/www/vpn-shop/logs/stderr.log

[Install]
WantedBy=multi-user.target
```

### 11.4 部署脚本

```bash
#!/bin/bash
# deploy.sh

set -e

# 项目路径
PROJECT_DIR="/var/www/vpn-shop"
BACKEND_DIR="$PROJECT_DIR/backend"
FRONTEND_DIR="$PROJECT_DIR/frontend"
CONFIG_FILE="$PROJECT_DIR/config.yaml"

echo "开始部署 VPN Shop..."

# 1. 停止服务
echo "停止服务..."
sudo systemctl stop vpn-shop || true

# 2. 拉取代码 (如果有Git)
# cd $PROJECT_DIR && git pull

# 3. 构建后端
echo "构建后端..."
cd $PROJECT_DIR
go build -o $BACKEND_DIR/vpn-shop ./cmd/server

# 4. 构建前端
echo "构建前端..."
cd $PROJECT_DIR/frontend
npm run build
rm -rf $FRONTEND_DIR/dist
mv dist $FRONTEND_DIR/

# 5. 设置权限
echo "设置权限..."
chown -R www-data:www-data $PROJECT_DIR

# 6. 启动服务
echo "启动服务..."
sudo systemctl daemon-reload
sudo systemctl start vpn-shop
sudo systemctl enable vpn-shop

# 7. 检查状态
echo "检查服务状态..."
sudo systemctl status vpn-shop --no-pager

echo "部署完成!"
```

---

## 12. 运维指南

### 12.1 常用运维命令

```bash
# 查看服务状态
sudo systemctl status vpn-shop

# 查看日志
sudo journalctl -u vpn-shop -f

# 重启服务
sudo systemctl restart vpn-shop

# 重载配置 (后端热重载)
curl -X POST http://localhost:8080/api/admin/reload

# 备份数据库
pg_dump -U vpn_admin vpn_shop > backup_$(date +%Y%m%d).sql

# 查看 3X-UI 状态
systemctl status x-ui
```

### 12.2 监控指标

| 指标 | 说明 | 告警阈值 |
|------|------|----------|
| 服务可用性 | HTTP 探测 | 不可用时告警 |
| 订单成功率 | 支付回调成功率 | < 95% 告警 |
| 平均响应时间 | API 响应时间 | > 2s 告警 |
| 磁盘使用 | 磁盘空间 | > 80% 告警 |
| 内存使用 | 内存占用 | > 85% 告警 |

### 12.3 数据备份策略

```bash
#!/bin/bash
# backup.sh

BACKUP_DIR="/var/backups/vpn-shop"
DATE=$(date +%Y%m%d_%H%M%S)

# 创建备份目录
mkdir -p $BACKUP_DIR

# 备份商业数据
pg_dump -U vpn_admin vpn_shop > $BACKUP_DIR/commerce_$DATE.sql

# 备份 3X-UI 数据库
cp /var/www/x-ui/db.sqlite $BACKUP_DIR/xui_$DATE.sqlite

# 备份配置文件
cp /var/www/vpn-shop/config.yaml $BACKUP_DIR/config_$DATE.yaml

# 压缩
cd $BACKUP_DIR
tar -czf backup_$DATE.tar.gz *.sql *.sqlite *.yaml

# 删除7天前的备份
find $BACKUP_DIR -name "*.tar.gz" -mtime +7 -delete

# 上传到远程存储 (可选)
# rclone copy $BACKUP_DIR/backup_$DATE.tar.gz remote:backups/
```

---

## 13. 安全建议

### 13.1 服务器安全

```bash
# 1. 配置防火墙
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp
sudo ufw enable

# 2. 禁用 root 登录
sudo passwd -l root

# 3. 配置 SSH 密钥登录
ssh-keygen -t ed25519
ssh-copy-id user@your-server

# 4. 安装 fail2ban 防暴力破解
sudo apt install fail2ban
sudo systemctl enable fail2ban

# 5. 定期更新系统
sudo apt update && sudo apt upgrade -y
```

### 13.2 API 安全

- 所有 API 使用 HTTPS
- Bearer Token 定期轮换
- 实现请求限流 (防止滥用)
- IP 白名单 (管理后台)
- 请求签名验证 (关键接口)

### 13.3 数据安全

- 数据库定期备份
- 敏感数据加密存储 (密码使用 bcrypt)
- 日志脱敏 (不记录完整信用卡号等)
- 符合 GDPR/当地数据保护法规

### 13.4 支付安全

- 回调地址仅允许支付平台 IP 访问
- 回调签名验证 (必须验证)
- 订单金额服务端校验 (防止篡改)
- 幂等性处理 (防止重复回调)

---

## 附录

### A. 环境变量参考

```bash
# .env 文件示例
APP_ENV=production
APP_PORT=8080
APP_SECRET=your-secret-key-here

# 数据库
DB_HOST=localhost
DB_PORT=5432
DB_USER=vpn_admin
DB_PASSWORD=your-db-password
DB_NAME=vpn_shop

# Redis
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=

# 3X-UI
XUI_API_URL=http://127.0.0.1:2053
XUI_API_TOKEN=your-xui-api-token
XUI_INBOUND_ID=1

# 虎皮椒支付
HUPIJIAO_APP_ID=your-app-id
HUPIJIAO_APP_KEY=your-app-key
HUPIJIAO_NOTIFY_URL=https://your-domain.com/api/callback/hupijiao

# 邮件
SMTP_HOST=smtp.qq.com
SMTP_PORT=587
SMTP_USERNAME=noreply@your-domain.com
SMTP_PASSWORD=your-smtp-password
EMAIL_FROM=noreply@your-domain.com

# 网站
SITE_NAME=VPN Store
SITE_URL=https://your-domain.com
```

### B. 常见问题排查

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| 支付回调失败 | 防火墙未放行 | 检查回调端口 |
| 签名验证失败 | AppKey 不匹配 | 核对虎皮椒配置 |
| 添加客户端失败 | API Token 错误 | 检查 Token |
| 订阅链接打不开 | 订阅服务未启动 | 重启 3X-UI |
| 邮件发送失败 | SMTP 配置错误 | 检查邮箱设置 |

### C. 联系与支持

如有问题，请通过以下方式联系：

- 邮件: support@your-domain.com
- 工单: https://your-domain.com/support

---

*文档版本: 1.0*
*最后更新: 2024*
