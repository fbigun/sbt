# sing-box 配置仓库工具链
#
# deps     : 安装校验依赖（python3 / python3-jsonschema / jq / curl / tar）
# install  : 安装依赖 + 各版本线最新 sing-box 到 bin/（s13 / s14）
# test     : 校验配置（JSON / schema / sing-box check）

SHELL := /bin/bash

GH       := https://github.com/SagerNet/sing-box/releases/download
REPO     := SagerNet/sing-box
BIN_DIR  := bin
ARCH     := $(shell uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')

# 各版本线目标二进制：v1.13.* -> s13，v1.14.* -> s14
S13_BIN := $(BIN_DIR)/s13
S14_BIN := $(BIN_DIR)/s14

# 测试节点：仅用于本地校验（空 outbounds 组缺少引用时会报 missing tags）
TEST_NODE := '{"type":"vless","tag":"测试节点","server":"127.0.0.1","server_port":443,"uuid":"00000000-0000-0000-0000-000000000000","tls":{"enabled":false}}'

# schema 校验对象：v1.13 属旧版本，字段与 schema_v1.14 不兼容，仅校验 v1.14 系配置
SCHEMA_FILES := v1.14.json tailscale-v1.14.json
# sing-box check 对象：按配置版本分派对应二进制
CHECK_S13 := v1.13.json
CHECK_S14 := v1.14.json tailscale-v1.14.json

# 文件目标：缺失时自动执行 install（install 本身仍是 phony，可随时强制重装）
$(S13_BIN):
	$(MAKE) install-s13
$(S14_BIN):
	$(MAKE) install-s14

.PHONY: deps install install-s13 install-s14 test check schema clean

# 版本号：各版本线最新（tag 去 v 前缀），GitHub releases 默认新在前
# 仅选择带 Linux 二进制（sing-box-<ver>-linux-<arch>.tar.gz）的版本，跳过只发 Android 产物的 release
s13_version = $(shell curl -fsSL https://api.github.com/repos/$(REPO)/releases | jq --arg a $(ARCH) -r '[.[] | select(.tag_name | startswith("v1.13.")) | select(any(.assets[]?; .name | test("linux-" + $$a + "\\.tar\\.gz$$"))) | .tag_name] | .[0]' | sed 's/^v//')
s14_version = $(shell curl -fsSL https://api.github.com/repos/$(REPO)/releases | jq --arg a $(ARCH) -r '[.[] | select(.tag_name | startswith("v1.14.")) | select(any(.assets[]?; .name | test("linux-" + $$a + "\\.tar\\.gz$$"))) | .tag_name] | .[0]' | sed 's/^v//')

# 校验依赖：已就绪则跳过，缺失时自动安装
deps:
	@command -v jq >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1 && echo "依赖已就绪" || { \
		echo "==> 安装校验依赖"; \
		apt-get update -qq && apt-get install -y --no-install-recommends python3 python3-jsonschema jq curl tar; \
	}

install: deps install-s13 install-s14

install-s13:
	@echo "==> 下载 sing-box v1.13 线（最新稳定版）"
	$(eval V := $(call s13_version))
	curl -fL -o /tmp/sing-box-s13.tar.gz \
		$(GH)/v$(V)/sing-box-$(V)-linux-$(ARCH).tar.gz
	@mkdir -p $(BIN_DIR)
	tar -xzf /tmp/sing-box-s13.tar.gz -C $(BIN_DIR) --strip-components=1
	@mv $(BIN_DIR)/sing-box $(S13_BIN)
	@chmod +x $(S13_BIN)
	@echo "==> 已安装: $(S13_BIN) (v$(V))"

install-s14:
	@echo "==> 下载 sing-box v1.14 线（最新 beta）"
	$(eval V := $(call s14_version))
	curl -fL -o /tmp/sing-box-s14.tar.gz \
		$(GH)/v$(V)/sing-box-$(V)-linux-$(ARCH).tar.gz
	@mkdir -p $(BIN_DIR)
	tar -xzf /tmp/sing-box-s14.tar.gz -C $(BIN_DIR) --strip-components=1
	@mv $(BIN_DIR)/sing-box $(S14_BIN)
	@chmod +x $(S14_BIN)
	@echo "==> 已安装: $(S14_BIN) (v$(V))"

test: check schema

# 注入测试节点后，按配置版本用对应 sing-box 校验
check: deps $(S13_BIN) $(S14_BIN)
	@set -e; for f in $(CHECK_S13); do \
		tmp="$$(mktemp --suffix=.json)"; \
		jq --argjson node $(TEST_NODE) \
			'(.outbounds[] | select(.outbounds? != null and (.outbounds | length) == 0) | .outbounds) += [$$node.tag] | .outbounds += [$$node]' \
			"$$f" > "$$tmp"; \
		$(S13_BIN) check -c "$$tmp" >/dev/null 2>&1 && echo "[check OK] $$f (s13)" || { echo "[check FAIL] $$f"; $(S13_BIN) check -c "$$tmp"; rm -f "$$tmp"; exit 1; }; \
		rm -f "$$tmp"; \
	done
	@set -e; for f in $(CHECK_S14); do \
		tmp="$$(mktemp --suffix=.json)"; \
		jq --argjson node $(TEST_NODE) \
			'(.outbounds[] | select(.outbounds? != null and (.outbounds | length) == 0) | .outbounds) += [$$node.tag] | .outbounds += [$$node]' \
			"$$f" > "$$tmp"; \
		$(S14_BIN) check -c "$$tmp" >/dev/null 2>&1 && echo "[check OK] $$f (s14)" || { echo "[check FAIL] $$f"; $(S14_BIN) check -c "$$tmp"; rm -f "$$tmp"; exit 1; }; \
		rm -f "$$tmp"; \
	done

# 用 schema_v1.14.json 校验 v1.14 系配置结构
schema: deps
	@set -e; for f in $(SCHEMA_FILES); do \
		python3 -c 'import json,sys,jsonschema; \
			json.load(open(sys.argv[1])); \
			jsonschema.validate(json.load(open(sys.argv[1])), json.load(open(sys.argv[2])))' \
			"$$f" schema_v1.14.json && echo "[schema OK] $$f" || { echo "[schema FAIL] $$f"; exit 1; }; \
	done

clean:
	rm -rf $(BIN_DIR)
