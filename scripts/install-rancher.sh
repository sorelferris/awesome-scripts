#!/bin/bash
set -euo pipefail  # 错误时退出、未定义变量报错、管道失败报错

##############################################################################
# 配置参数（用户可根据实际需求修改）
##############################################################################
# Rancher 访问域名（需提前解析到k3s集群任意节点IP）
RANCHER_HOSTNAME="rancher.yourdomain.com"
# Let's Encrypt 邮箱（用于自动申请SSL证书，无则填空）
LETS_ENCRYPT_EMAIL="your-email@example.com"
# Rancher 版本（建议使用稳定版，参考：https://releases.rancher.com/server-charts/latest/）
RANCHER_VERSION="2.10.1"
# Cert-Manager 版本（需与Rancher兼容，参考：https://cert-manager.io/docs/installation/compatibility/）
CERT_MANAGER_VERSION="v1.12.4"
# 超时时间（秒）
TIMEOUT=30
# 国内镜像开关（1=启用国内镜像加速，0=使用官方镜像）
USE_CN_MIRROR=1

##############################################################################
# 日志函数（彩色输出，区分信息/成功/错误）
##############################################################################
info() { echo -e "\033[34m[INFO] $1\033[0m"; }
success() { echo -e "\033[32m[SUCCESS] $1\033[0m"; }
error() { echo -e "\033[31m[ERROR] $1\033[0m"; exit 1; }
warn() { echo -e "\033[33m[WARN] $1\033[0m"; }

##############################################################################
# 1. 前置依赖检查（k3s、kubectl、Helm）
##############################################################################
check_dependencies() {
    info "=== 开始检查前置依赖 ==="

    # 检查k3s集群状态（必须正常运行且节点Ready）
    info "检查k3s集群状态..."
    if ! command -v kubectl &> /dev/null; then
        # 尝试使用k3s自带kubectl
        if command -v k3s &> /dev/null; then
            alias kubectl="k3s kubectl"
            info "已使用k3s自带kubectl"
        else
            error "未找到kubectl或k3s，需先安装k3s集群！"
        fi
    fi

    # 检查k3s节点是否Ready
    local node_ready=0
    for ((i=0; i<TIMEOUT; i++)); do
        if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
            node_ready=1
            break
        fi
        sleep 2
    done
    if [ $node_ready -eq 0 ]; then
        error "k3s集群节点未处于Ready状态，请先确保k3s正常运行！"
    fi
    success "k3s集群状态正常（节点Ready）"

    # 检查Helm 3+是否安装
    info "检查Helm版本（需≥v3）..."
    if ! command -v helm &> /dev/null; then
        warn "未安装Helm，开始自动安装Helm 3..."
        # 自动安装Helm（适配amd64/arm64架构）
        local arch=$(uname -m)
        local helm_url=""
        if [ "$arch" = "x86_64" ]; then
            helm_url="https://get.helm.sh/helm-v3.14.0-linux-amd64.tar.gz"
        elif [ "$arch" = "aarch64" ]; then
            helm_url="https://get.helm.sh/helm-v3.14.0-linux-arm64.tar.gz"
        else
            error "不支持的架构：$arch，请手动安装Helm！"
        fi

        # 下载并安装Helm
        curl -fsSL "$helm_url" -o helm.tar.gz || error "Helm安装包下载失败，请检查网络！"
        tar -zxf helm.tar.gz || error "Helm安装包解压失败！"
        sudo mv linux-*/helm /usr/local/bin/ || error "Helm移动到执行路径失败！"
        rm -rf helm.tar.gz linux-*
    fi

    # 验证Helm版本
    local helm_ver=$(helm version --short | grep -oE "v3\.[0-9]+\.[0-9]+" | cut -c2-)
    if ! echo "$helm_ver" | awk -F. '$1>=3 {exit 0} {exit 1}'; then
        error "Helm版本过低（当前：v$helm_ver），需升级到v3+！"
    fi
    success "Helm版本验证通过（v$helm_ver）"

    info "=== 前置依赖检查完成 ==="
}

##############################################################################
# 2. 清理Cert-Manager残留（解决CRD冲突问题）
##############################################################################
cleanup_cert_manager() {
    info "=== 开始清理Cert-Manager残留资源 ==="

    # 检查是否存在Cert-Manager Helm Release
    if helm list -n cert-manager | grep -q "cert-manager"; then
        info "发现旧的Cert-Manager Helm实例，开始卸载..."
        helm uninstall cert-manager -n cert-manager 2>/dev/null || warn "旧Cert-Manager卸载失败（可能已部分清理）"
    fi

    # 删除Cert-Manager命名空间（强制清理残留资源）
    if kubectl get ns | grep -q "cert-manager"; then
        info "删除Cert-Manager命名空间（可能需要30秒）..."
        kubectl delete ns cert-manager --grace-period=0 --force 2>/dev/null || true
        # 等待命名空间删除完成
        local ns_deleted=0
        for ((i=0; i<TIMEOUT; i++)); do
            if ! kubectl get ns | grep -q "cert-manager"; then
                ns_deleted=1
                break
            fi
            sleep 2
        done
        if [ $ns_deleted -eq 0 ]; then
            warn "Cert-Manager命名空间删除超时，可能残留资源，将继续尝试清理CRD"
        else
            success "Cert-Manager命名空间删除完成"
        fi
    fi

    # 批量删除Cert-Manager相关CRD（避免安装冲突）
    local crd_list=(
        "certificates.cert-manager.io"
        "certificaterequests.cert-manager.io"
        "challenges.acme.cert-manager.io"
        "clusterissuers.cert-manager.io"
        "issuers.cert-manager.io"
        "orders.acme.cert-manager.io"
    )
    for crd in "${crd_list[@]}"; do
        if kubectl get crd | grep -q "$crd"; then
            info "删除残留CRD：$crd"
            kubectl delete crd "$crd" --grace-period=0 --force 2>/dev/null || warn "CRD $crd 删除失败（可能已不存在）"
        fi
    done

    success "=== Cert-Manager残留清理完成 ==="
}

##############################################################################
# 3. 安装Cert-Manager（Rancher依赖）
##############################################################################
install_cert_manager() {
    info "=== 开始安装Cert-Manager $CERT_MANAGER_VERSION ==="

    # 添加Cert-Manager仓库（国内镜像或官方）
    if [ $USE_CN_MIRROR -eq 1 ]; then
        info "使用国内镜像添加Cert-Manager仓库..."
        # 检查仓库是否已存在
        if helm repo list | grep -q "jetstack"; then
            info "jetstack仓库已存在，更新仓库..."
            helm repo update jetstack || error "Cert-Manager仓库更新失败！"
        else
            helm repo add jetstack "https://mirror.helm.sh/charts/jetstack/cert-manager" || error "Cert-Manager国内仓库添加失败！"
            helm repo update jetstack || error "Cert-Manager仓库更新失败！"
        fi
    else
        info "使用官方仓库添加Cert-Manager..."
        # 检查仓库是否已存在
        if helm repo list | grep -q "jetstack"; then
            info "jetstack仓库已存在，更新仓库..."
            helm repo update jetstack || error "Cert-Manager仓库更新失败！"
        else
            helm repo add jetstack "https://charts.jetstack.io" || error "Cert-Manager官方仓库添加失败！"
            helm repo update jetstack || error "Cert-Manager仓库更新失败！"
        fi
    fi

    # 创建Cert-Manager命名空间
    kubectl create namespace cert-manager 2>/dev/null || error "Cert-Manager命名空间创建失败（可能已存在，需先清理）"

    # 安装Cert-Manager（自动安装CRD）
    info "执行Cert-Manager安装命令..."
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version "$CERT_MANAGER_VERSION" \
        --set installCRDs=true \
        --set image.repository="quay.io/jetstack/cert-manager-controller" \
        --set image.tag="$CERT_MANAGER_VERSION" \
        --set webhook.image.repository="quay.io/jetstack/cert-manager-webhook" \
        --set webhook.image.tag="$CERT_MANAGER_VERSION" \
        --set cainjector.image.repository="quay.io/jetstack/cert-manager-cainjector" \
        --set cainjector.image.tag="$CERT_MANAGER_VERSION" || error "Cert-Manager安装失败！"

    # 验证Cert-Manager Pod状态（等待所有Pod Running）
    info "等待Cert-Manager Pod启动（超时$TIMEOUT秒）..."
    local pod_ready=0
    for ((i=0; i<TIMEOUT; i++)); do
        # 检查3个核心Pod是否全部Running
        local running_pods=$(kubectl -n cert-manager get pods --no-headers 2>/dev/null | grep -c "Running")
        if [ "$running_pods" -eq 3 ]; then
            pod_ready=1
            break
        fi
        sleep 2
    done
    if [ $pod_ready -eq 0 ]; then
        error "Cert-Manager Pod启动超时！当前状态："
        kubectl -n cert-manager get pods
        exit 1
    fi

    success "=== Cert-Manager $CERT_MANAGER_VERSION 安装完成 ==="
}

##############################################################################
# 4. 安装Rancher
##############################################################################
install_rancher() {
    info "=== 开始安装Rancher $RANCHER_VERSION ==="

    # 添加Rancher仓库（国内镜像或官方）
    if [ $USE_CN_MIRROR -eq 1 ]; then
        info "使用国内镜像添加Rancher仓库..."
        # 检查仓库是否已存在
        if helm repo list | grep -q "rancher-latest"; then
            info "rancher-latest仓库已存在，更新仓库..."
            helm repo update rancher-latest || error "Rancher仓库更新失败！"
        else
            helm repo add rancher-latest "https://releases.rancher.cn/server-charts/latest" || error "Rancher国内仓库添加失败！"
            helm repo update rancher-latest || error "Rancher仓库更新失败！"
        fi
    else
        info "使用官方仓库添加Rancher..."
        # 检查仓库是否已存在
        if helm repo list | grep -q "rancher-latest"; then
            info "rancher-latest仓库已存在，更新仓库..."
            helm repo update rancher-latest || error "Rancher仓库更新失败！"
        else
            helm repo add rancher-latest "https://releases.rancher.com/server-charts/latest" || error "Rancher官方仓库添加失败！"
            helm repo update rancher-latest || error "Rancher仓库更新失败！"
        fi
    fi

    # 创建Rancher命名空间
    kubectl create namespace cattle-system 2>/dev/null || error "Rancher命名空间创建失败！"

    # 配置证书来源（Let's Encrypt或自签名）
    local tls_source="letsEncrypt"
    local tls_args=""
    if [ -z "$LETS_ENCRYPT_EMAIL" ]; then
        warn "未配置Let's Encrypt邮箱，将使用自签名证书（仅测试用）"
        tls_source="selfSigned"
    else
        tls_args="--set letsEncrypt.email=$LETS_ENCRYPT_EMAIL"
    fi

    # 安装Rancher（国内镜像优化）
    info "执行Rancher安装命令（证书来源：$tls_source）..."
    helm install rancher rancher-latest/rancher \
        --namespace cattle-system \
        --version "$RANCHER_VERSION" \
        --set hostname="$RANCHER_HOSTNAME" \
        --set ingress.tls.source="$tls_source" \
        $tls_args \
        --set global.cattle.psp.enabled=false \
        --set image.repository="rancher/rancher" \
        --set image.tag="v$RANCHER_VERSION" \
        --set image.pullPolicy="IfNotPresent" \
        --set replicas=3 || error "Rancher安装失败！"

    # 验证Rancher Pod状态（等待所有Pod Running）
    info "等待Rancher Pod启动（超时$TIMEOUT秒）..."
    local rancher_ready=0
    for ((i=0; i<TIMEOUT; i++)); do
        local running_rancher=$(kubectl -n cattle-system get pods --no-headers 2>/dev/null | grep -c "Running")
        if [ "$running_rancher" -ge 1 ]; then  # 至少1个Pod Running即视为可用
            rancher_ready=1
            break
        fi
        sleep 3
    done
    if [ $rancher_ready -eq 0 ]; then
        error "Rancher Pod启动超时！当前状态："
        kubectl -n cattle-system get pods
        exit 1
    fi

    # 验证Ingress配置
    info "验证Rancher Ingress配置..."
    if ! kubectl -n cattle-system get ingress rancher 2>/dev/null; then
        warn "Rancher Ingress未自动创建，将手动创建..."
        cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rancher
  namespace: cattle-system
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  rules:
  - host: $RANCHER_HOSTNAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: rancher
            port:
              number: 80
  tls:
  - hosts:
    - $RANCHER_HOSTNAME
    secretName: tls-rancher-ingress
EOF
    fi
    success "Rancher Ingress配置完成"

    success "=== Rancher $RANCHER_VERSION 安装完成 ==="
}

##############################################################################
# 5. 输出安装结果（访问地址、初始密码）
##############################################################################
print_result() {
    info "=== 安装结果汇总 ==="

    # 获取Rancher初始密码
    local bootstrap_password=""
    if kubectl -n cattle-system get secret bootstrap-secret 2>/dev/null; then
        bootstrap_password=$(kubectl -n cattle-system get secret bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}{{"\n"}}')
    else
        warn "未找到bootstrap-secret，可能使用了自定义密码（安装时通过--set bootstrapPassword指定）"
    fi

    # 输出关键信息
    echo -e "\n\033[32m=============================================\033[0m"
    echo -e "\033[32m          Rancher安装成功！\033[0m"
    echo -e "\033[32m=============================================\033[0m"
    echo -e "🔗 访问地址：https://$RANCHER_HOSTNAME"
    echo -e "🔑 初始密码：$bootstrap_password"
    echo -e "📝 说明："
    echo -e "   1. 若使用Let's Encrypt证书，需等待1-2分钟生效"
    echo -e "   2. 首次登录需修改初始密码"
    echo -e "   3. 若无法访问，检查域名解析和节点80/443端口是否开放"
    echo -e "\033[32m=============================================\033[0m\n"
}

##############################################################################
# 主执行流程
##############################################################################
main() {
    echo -e "\033[32m=============================================\033[0m"
    echo -e "\033[32m        一键安装Rancher管理工具（v$RANCHER_VERSION）\033[0m"
    echo -e "\033[32m=============================================\033[0m\n"

    # 执行各步骤
    check_dependencies
    cleanup_cert_manager
    install_cert_manager
    install_rancher
    print_result

    success "所有安装步骤完成！请访问上述地址使用Rancher。"
}

# 启动主流程
main
