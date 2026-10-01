# TDP GitOps

Repositório de manifests ArgoCD para deploy dos componentes da Tecnisys Data Platform (TDP) no Kubernetes, usando o padrão **App of Apps**.

## Visão geral

Este repositório conduz o deploy dos componentes da TDP (Tecnisys Data Platform) — Ozone, Trino, Spark, Airflow, Kafka, Superset e outros — em clusters Kubernetes usando o padrão App of Apps do ArgoCD. Os manifests das Applications ficam como templates envsubst em `available/`, são renderizados por ambiente em `current/` (a fonte da verdade que o ArgoCD monitora) e referenciam Helm charts versionados no registry OCI da Tecnisys. Um único script, `deploy.sh`, cuida do bootstrap do ArgoCD, da renderização dos templates e dos modos de deploy GitOps (via git) e direto (`kubectl apply`).

### Como funciona

```
deploy.sh                 seu repositório git       ArgoCD
─────────                 ───────────────────       ──────
available/ ─┐  renderiza  current/       monitora   App of Apps (em ARGOCD_NAMESPACE)
common/   ──┴──────────►  ├─ common/   ◄──────────     │ cria uma Application por componente
                          ├─ tdp-ozone/                ▼
                          └─ tdp-trino/  ◄──────────  Applications (em TDP_PROJECT_NAMESPACE)
                                         values        │ Helm chart de registry.tecnisys.com.br
                                                       ▼
                                                     Workloads (em TDP_NAMESPACE)
```

- `available/` e `common/` contêm os **templates** (com `${VAR}`) — **nunca** aplicados diretamente.
- `deploy.sh -p` renderiza `common/` (e os componentes informados) → `current/`, substituindo as variáveis.
- `current/` é **commitado no git** e monitorado pelo App of Apps. Cada Application instala seu chart a partir do registry, com os arquivos de values de `current/<componente>/`.
- Os Secrets renderizados (`current/common/*-secret.yaml`) contêm as credenciais do git e do registry: ficam no `.gitignore`, são excluídos do App of Apps e só o `deploy.sh` os aplica. **Nunca commite esses arquivos.**
- Charts e imagens vêm **somente de `registry.tecnisys.com.br`**: `community/*` é público, `tdp/*` exige o image pull secret `tdp-registry`, que o `deploy.sh` cria.

### Estrutura

```
tdp-gitops/
├── common/           # Templates de bootstrap: AppProject, App of Apps, Secrets de repositório e de pull
├── available/        # Uma pasta por componente TDP:
│   ├── tdp-airflow/      #   tdp-airflow.yaml          a Application do ArgoCD
│   │                     #   values.yaml               padrões do chart
│   │                     #   values-gitops.yaml        padrões GitOps (overlay opcional)
│   │                     #   values-integration.yaml   integração com outros componentes (overlay opcional)
│   ├── tdp-clickhouse/
│   ├── …
│   └── tdp-trino/
├── current/          # Renderizado pelo deploy.sh — commitado no git,
│                     # exceto current/common/*-secret.yaml (no .gitignore)
├── variables.env     # Variáveis de referência (não editar, copiar para variables.env.local)
├── deploy.sh         # Script de renderização e deploy
└── README.md
```

---

## Pré-requisitos

| Item | Requisito |
| --- | --- |
| Cluster | Kubernetes 1.32+, OpenShift 4.19+ ou Rancher 2.10.x+ |
| Estação de trabalho | `kubectl` configurado para o cluster, `helm` 3, `envsubst` (pacote `gettext`), `git` |
| Conta no registry | Usuário ou conta robot em `registry.tecnisys.com.br`, usada para os charts e para as imagens privadas |
| Servidor git | Um repositório vazio que o ArgoCD consiga acessar, e um token para ele |
| Classes do cluster | Uma IngressClass e uma StorageClass, ou classes padrão no cluster para ambas |
| Instalados pelo administrador do cluster | `tdp-license` (controle de licença) e `tdp-operator` (operators do Kafka e do ClickHouse), via `helm install`, fora deste fluxo GitOps |

---

## Instalação

### Passo 1 — Criar o seu repositório GitOps

Este repositório (**Tecnisys-OSS/tdp-k8s-gitops**) é a fonte de distribuição — mantida sincronizada a cada release da TDP e sobrescrita a cada sincronização. Use-o como ponto de partida para **o seu próprio** repositório, aquele que o ArgoCD vai monitorar:

```bash
# Obter o kit
git clone https://github.com/Tecnisys-OSS/tdp-k8s-gitops.git meu-tdp-gitops
cd meu-tdp-gitops

# Apontar para o seu próprio repositório, vazio, e publicar
git remote set-url origin https://git.example.com/<org>/meu-tdp-gitops.git
git push -u origin main
```

O App of Apps acompanha o branch **`main`**.

### Passo 2 — Configurar o `variables.env.local`

```bash
cp variables.env variables.env.local
```

O `variables.env.local` está no `.gitignore`. Ele é lido pelo bash (`source`), então **use aspas simples em qualquer valor com `$`**, como uma conta robot do Harbor (`TECNISYS_HELM_REGISTRY_USER='robot$tdp+pull'`).

| Variável | Exemplo | Uso |
| --- | --- | --- |
| `ARGOCD_NAMESPACE` | `tdp-system` | Onde o ArgoCD é instalado (e onde fica o App of Apps) |
| `TDP_NAMESPACE` | `tdp` | Onde rodam os pods dos componentes, e o pull secret `tdp-registry` |
| `TDP_PROJECT_NAMESPACE` | `tdp` | Onde ficam as Applications dos componentes |
| `TDP_APPLICATIONS` | `argo-gitops-tdp` | Nome do App of Apps |
| `GIT_REPO_URL`, `GIT_REPO_USER`, `GIT_REPO_TOKEN_OR_PASS` | seu repositório | O repositório que o ArgoCD monitora |
| `HELM_CHART_REPO_URL`, `HELM_CHART_VERSION` | `registry.tecnisys.com.br/tdp/charts`, `3.0.2` | De onde vêm os charts |
| `KUBERNETES_SERVER` | `https://kubernetes.default.svc` | Cluster de destino (in-cluster por padrão) |
| `TECNISYS_HELM_REGISTRY_USER`, `TECNISYS_HELM_REGISTRY_TOKEN` | `'robot$tdp+pull'` | Pull dos charts (ArgoCD) e das imagens (secret `tdp-registry`) |
| `TDP_DOMAIN` | `example.com` | Hosts de Ingress/Gateway API: `airflow.example.com`, … (padrão `tdp.local`; `-d` tem precedência) |
| `TDP_INGRESS_CLASS`, `TDP_STORAGE_CLASS` | `nginx`, `local-path` | Gravadas em todos os `values-gitops.yaml`; vazio = padrão do chart e a classe padrão do cluster |
| `TDP_EXPOSE` | `ingress` | Como os componentes com endpoint web são expostos: `ingress`, `gatewayapi` ou `none` (padrão; `-e` tem precedência) |
| `TDP_GATEWAY_NAME`, `TDP_GATEWAY_NAMESPACE` | `tdp-gateway`, `gateway-system` | Com `gatewayapi`: o Gateway existente ao qual as HTTPRoutes se ligam (obrigatório) |

### Passo 3 — Instalar os CRDs e o ArgoCD

```bash
./deploy.sh --install -v variables.env.local
```

O que é executado, em ordem:

1. `helm registry login` — autentica no registry OCI.
2. `helm upgrade --install tdp-crds` — os CRDs do cluster; pulado quando os CRDs do ArgoCD já existem.
3. `helm upgrade --install tdp-argo` — o ArgoCD em `ARGOCD_NAMESPACE`, com `application.namespaces: "*"`, para gerenciar Applications em qualquer namespace, e a interface exposta em `argo.${TDP_DOMAIN}` conforme `TDP_EXPOSE` (veja o Passo 4); aguarda o server e o application controller.
4. `envsubst` em `common/` → `current/common/`. Os componentes são renderizados à parte, no Passo 6.
5. `kubectl apply` de `current/common/` (criando o `TDP_NAMESPACE` se necessário):
   - `argo-gitops-appproject.yaml` — o AppProject da TDP
   - `tdp-devops-repo-secret.yaml` — credencial git para o ArgoCD
   - `tdp-registry-secret.yaml` — credencial do Helm OCI registry para o ArgoCD
   - `tdp-image-pull-secret.yaml` — o image pull secret `tdp-registry` em `TDP_NAMESPACE`. Um `tdp-registry` existente é mantido, a menos que se use `--force`.
   - `argo-gitops-app-of-apps.yaml` — o App of Apps

> **Usando um ArgoCD instalado por você?** Pule o `--install` e rode `./deploy.sh -c -v variables.env.local`. Garanta que esse ArgoCD gerencie Applications em `TDP_PROJECT_NAMESPACE`:
>
> ```bash
> kubectl patch configmap argocd-cm -n <namespace-do-argocd> --type merge \
>   -p '{"data":{"application.namespaces":"<TDP_PROJECT_NAMESPACE>"}}'
> kubectl rollout restart deployment argocd-server -n <namespace-do-argocd>
> kubectl rollout restart statefulset argocd-application-controller -n <namespace-do-argocd>
> ```

### Passo 4 — Expor a interface do ArgoCD

O `--install` expõe a interface do ArgoCD do mesmo jeito que os componentes, sem precisar de `helm upgrade` depois:

| `TDP_EXPOSE` / `-e` | O que o `tdp-argo` recebe |
| ------------------- | ------------------------- |
| `ingress` | Um Ingress para `argo.${TDP_DOMAIN}`, com a `TDP_INGRESS_CLASS` (o padrão do chart, `nginx`, quando vazia) |
| `gatewayapi` | Uma HTTPRoute para `argo.${TDP_DOMAIN}` no `TDP_GATEWAY_NAME` em `TDP_GATEWAY_NAMESPACE` (`TDP_NAMESPACE` quando vazio). A rota fica em `ARGOCD_NAMESPACE`, então o listener do Gateway precisa aceitar rotas desse namespace |
| `none` | Nenhum Ingress nem rota. Acesse a interface com `kubectl -n <ARGOCD_NAMESPACE> port-forward svc/tdp-argocd-server 8080:80` |

Em todos os modos, a URL do próprio ArgoCD (`configs.cm.url`) passa a ser `https://argo.${TDP_DOMAIN}`, para que redirecionamentos e callbacks de SSO batam com o host.

Para mudar a exposição ou o domínio depois, rode `./deploy.sh --install` de novo com as novas configurações. Ele atualiza o `tdp-argo` no lugar, refaz os values a partir do arquivo de variáveis e descarta flags definidas à mão. Sem configuração de TLS, o Ingress serve o certificado padrão do controller.

### Passo 5 — Publicar o bootstrap e entrar

O App of Apps lê `current/` **do repositório git**, então publique-o. Os Secrets renderizados estão no `.gitignore` e ficam só na sua máquina.

```bash
git add current/
git commit -m "chore: bootstrap TDP GitOps"
git push origin main

# O App of Apps deve aparecer como Synced
kubectl -n tdp-system get applications

# Senha inicial do admin para a interface
kubectl -n tdp-system get secret tdp-argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Passo 6 — Renderizar as aplicações

Sem nomes de componentes, o `deploy.sh` renderiza apenas `current/common/`. Informe os componentes desejados, ou use `--all-components`:

```bash
# Alguns componentes
./deploy.sh -p -v variables.env.local tdp-ozone tdp-hive-metastore tdp-trino

# Tudo de available/, com hosts como airflow.example.com
./deploy.sh -p -v variables.env.local -d example.com --all-components

# Expostos via Ingress, ou via HTTPRoutes do Gateway API em um Gateway existente
./deploy.sh -p -v variables.env.local -e ingress tdp-trino tdp-superset
./deploy.sh -p -v variables.env.local -e gatewayapi tdp-trino tdp-superset   # exige TDP_GATEWAY_NAME
```

Cada componente vai para `current/<componente>/`: o manifesto da Application mais até três arquivos de values (veja [Arquivos de values](#arquivos-de-values)).

- A renderização só adiciona ou atualiza arquivos: componentes que já estão em `current/` e não foram informados continuam lá, para o App of Apps não removê-los (prune).
- Um `current/<componente>/values*.yaml` existente pode ter edições suas, então ele é **mantido** (com um aviso), a menos que você use `--force`. O manifesto da Application é sempre atualizado.
- O `deploy.sh` avisa se algo em `current/` apontar para um registry diferente de `registry.tecnisys.com.br`.
- A **exposição** (`TDP_EXPOSE` / `-e`) define o `TDP-Settings.gateway.ingress.enabled` e o `TDP-Settings.gateway.gatewayApi.enabled` de cada componente no `values-gitops.yaml`; os dois são mutuamente exclusivos. Os hosts são `<componente>.${TDP_DOMAIN}` nos dois modos, os Ingress usam a `TDP_INGRESS_CLASS` e as HTTPRoutes se ligam ao `TDP_GATEWAY_NAME` (o Gateway próprio de cada release, dos charts, fica desligado). Para mudar a exposição de um componente já renderizado, renderize-o de novo com `--force` ou edite o `values-gitops.yaml` dele. O Spark recebe dois hosts, cada um com um Ingress ou uma HTTPRoute: a interface do Master em `spark.${TDP_DOMAIN}` e o History Server em `spark-history.${TDP_DOMAIN}` (ligado no `tdp-spark/values-integration.yaml`, com os event logs em `s3a://warehouse/spark-events`).

### Passo 7 — Publicar e deixar o ArgoCD sincronizar

```bash
git add current/
git commit -m "feat: add tdp-ozone, tdp-hive-metastore, tdp-trino"
git push origin main

# Acompanhar as Applications e os pods
kubectl -n tdp get applications            # Synced / Healthy
kubectl -n tdp get pods -w
```

O App of Apps cria cada nova Application; cada Application instala seu chart de `registry.tecnisys.com.br` com os values do seu repositório, com sync automático, self-heal e prune.

O **modo direto** aplica uma Application com `kubectl`, sem passar pelo App of Apps — o ArgoCD continua lendo os arquivos de values do git, então publique-os mesmo assim:

```bash
./deploy.sh -a -v variables.env.local tdp-trino
```

### Ordem sugerida de implantação

O ArgoCD pode sincronizar tudo de uma vez, mas componentes integrados pelo `values-integration.yaml` sobem sem erros quando as suas dependências já estão rodando:

| Ordem | Componentes | Observações |
| --- | --- | --- |
| 1. Armazenamento de objetos | `tdp-ozone` | Crie os buckets `warehouse` e `clickhouse-data` no volume `/s3v` do Ozone |
| 2. Metadados e engines | `tdp-hive-metastore`, `tdp-spark`, `tdp-iceberg`, `tdp-trino` | Usam o S3 Gateway do Ozone |
| 3. Serviço e BI | `tdp-clickhouse`, `tdp-superset` | O Superset importa os datasources do ClickHouse e do Trino |
| 4. Qualquer ordem | `tdp-airflow`, `tdp-kafka`, `tdp-nifi`, `tdp-jupyter` e os demais | Kafka e ClickHouse precisam do `tdp-operator` |

---

## Arquivos de values

Cada Application aplica até três arquivos de values de `current/<componente>/`, nesta ordem — os posteriores prevalecem:

| Arquivo | Conteúdo | Na sincronização de release |
| --- | --- | --- |
| `values.yaml` | Padrões do chart (cópia do `values.yaml` do próprio chart) | Substituído pelos novos padrões do chart |
| `values-gitops.yaml` | Padrões GitOps: correções específicas do ArgoCD (ex.: Jobs de migração do Airflow como hooks Sync), autenticação S3 do Ozone desligada enquanto o Kerberos estiver desligado, a ingress/storage class de `TDP_INGRESS_CLASS`/`TDP_STORAGE_CLASS`, a exposição de `TDP_EXPOSE`, espelhos de imagem em produção | Mantido |
| `values-integration.yaml` | Integração com os outros componentes TDP em `TDP_NAMESPACE`: catálogos do Trino (hive, iceberg, clickhouse), Spark, Hive Metastore e ClickHouse no S3 do Ozone, datasources do Superset | Mantido |

- Maps são mesclados chave a chave, então um overlay só contém as chaves que muda. Listas e strings de várias linhas são substituídas por inteiro.
- Uma `TDP_INGRESS_CLASS`/`TDP_STORAGE_CLASS` vazia é renderizada como `null`, o que remove a chave: vale o padrão do chart.
- Os overlays são opcionais: apague um deles de `current/<componente>/` para não usá-lo (as Applications usam `ignoreMissingValueFiles: true`).
- O `values-integration.yaml` supõe que os componentes referenciados estão instalados com os nomes padrão em `TDP_NAMESPACE`, e traz senhas de exemplo (`change-me-*`) que precisam ser trocadas, de forma consistente entre ClickHouse, Trino e Superset, antes de uso real.
- O ArgoCD não substitui variáveis: tudo em `current/` precisa ser renderizado pelo `deploy.sh` antes de publicar.

### Customização de valores

Edite os arquivos em `current/<componente>/` — é isso que o ArgoCD lê, e o `deploy.sh` os mantém ao renderizar de novo. Prefira o `values-gitops.yaml` (ou um novo overlay) para as suas mudanças, para que o `values.yaml` possa depois ser atualizado a partir de um release mais novo com `--force`:

```bash
vim current/tdp-trino/values-gitops.yaml
git add current/tdp-trino/
git commit -m "chore: tune trino"
git push origin main
# O ArgoCD sincroniza automaticamente
```

---

## Operação no dia a dia

| Tarefa | Como |
| --- | --- |
| Mudar uma configuração | Editar `current/<componente>/values-gitops.yaml`, commitar e publicar |
| Atualizar os charts | Definir `HELM_CHART_VERSION` e renderizar de novo os componentes que já estão em `current/` (veja abaixo) |
| Adotar novos padrões do chart | Renderizar o componente de novo com `--force` (sobrescreve os arquivos de values dele) |
| Adicionar um componente | Renderizá-lo (Passo 6), commitar e publicar |
| Remover um componente | Apagar `current/<componente>/` e publicar: o ArgoCD remove a Application (prune) e executa os hooks de limpeza |
| Trocar as credenciais do registry | Atualizar o `variables.env.local` e rodar `./deploy.sh -c -v variables.env.local --force` |

Atualizar a versão dos charts:

```bash
# 1. Atualizar HELM_CHART_VERSION em variables.env.local
vim variables.env.local

# 2. Rerenderizar as Applications dos componentes que já estão em current/
#    (não use --all-components aqui: isso adicionaria todos os componentes)
./deploy.sh -v variables.env.local -p $(ls -d current/tdp-*/ | xargs -n1 basename)

# 3. Commitar
git add current/
git commit -m "chore: bump chart version to X.Y.Z"
git push origin main
```

### Atualizar um repositório criado com um kit antigo

Kits antigos commitavam `current/common/*-secret.yaml` e renderizavam Applications que só liam o `values.yaml`. Para migrar um repositório existente para este formato:

1. Copie os arquivos do novo kit (`deploy.sh`, `common/`, `available/`, `.gitignore`, `variables.env`) para o seu repositório e adicione as novas variáveis ao `variables.env.local`.
2. Aplique primeiro os recursos comuns: `./deploy.sh -c -v variables.env.local`. Isso coloca `Prune=false` nos Secrets de repositório antes que o novo App of Apps (que os exclui) sincronize, para que o ArgoCD nunca os apague.
3. Pare de versionar os Secrets renderizados: `git rm --cached current/common/*-secret.yaml`.
4. Renderize de novo os componentes que você usa (os manifestos das Applications passam a listar os overlays; o seu `values.yaml` atual é mantido): `./deploy.sh -p -v variables.env.local $(ls -d current/tdp-*/ | xargs -n1 basename)`.
5. Commite e publique. **Troque os tokens do git e do registry**: eles continuam no histórico do repositório.

---

## Referência do deploy.sh

```
./deploy.sh [OPÇÕES] [COMPONENTES... | --all-components]
```

| Flag | Descrição |
| --- | --- |
| `--install` | **Primeira instalação**: helm login → tdp-crds → tdp-argo (exposto em `argo.${TDP_DOMAIN}` conforme `TDP_EXPOSE`) → aguarda ready → renderiza → aplica common |
| `-v FILE` | Usar arquivo de variáveis customizado (padrão: `variables.env`) |
| `-p` | Apenas renderizar → `current/` (sem aplicar) |
| `-c` | Aplicar apenas recursos comuns (`current/common/`) via kubectl |
| `-a` | Aplicar apenas as Applications dos componentes selecionados via kubectl (não aplica common) |
| `--all-components` | Selecionar todos os componentes de `available/` (em vez de listá-los) |
| `-d DOMAIN` | Domínio dos hostnames de Ingress/Gateway API; tem precedência sobre `TDP_DOMAIN` |
| `-e MODE` | Exposição: `ingress`, `gatewayapi` ou `none`; tem precedência sobre `TDP_EXPOSE` |
| `-f`, `--force` | Sobrescrever `current/<componente>/values*.yaml` existentes, e substituir um pull secret `tdp-registry` existente |
| `-h` | Exibir ajuda |

- **Sem argumentos**, exibe a ajuda.
- **Sem componentes**, renderiza (e, sem `-p`, aplica) apenas `current/common/`.
- Sem `-p`, `-c` ou `-a`, o `deploy.sh` aplica os recursos comuns mais as Applications dos componentes selecionados.

### Exemplos

```bash
# Primeira instalação completa (instala ArgoCD + bootstrap)
./deploy.sh --install -v variables.env.local

# Renderizar componentes e publicar (modo GitOps)
./deploy.sh -p -v variables.env.local tdp-ozone tdp-trino
git add current/ && git commit -m "chore: render" && git push

# Renderizar todos os componentes, com hosts como airflow.example.com
./deploy.sh -p -v variables.env.local -d example.com --all-components

# Passar um componente já renderizado para Ingress (--force reescreve os arquivos de values)
./deploy.sh -p -v variables.env.local -e ingress --force tdp-trino

# Re-aplicar apenas recursos comuns (AppProject, Secrets, App of Apps)
./deploy.sh -c -v variables.env.local

# Deploy direto de um, vários ou todos os componentes (sem passar a Application pelo git)
./deploy.sh -a -v variables.env.local tdp-trino
./deploy.sh -a -v variables.env.local tdp-ozone tdp-trino
./deploy.sh -a -v variables.env.local --all-components
```

---

## Componentes disponíveis

| Componente | Descrição | Observações |
| --- | --- | --- |
| `tdp-airflow` | Apache Airflow | |
| `tdp-clickhouse` | ClickHouse | Precisa do `tdp-operator`; integração: disco S3 no Ozone, usuários `trino`/`superset` |
| `tdp-cloudbeaver` | CloudBeaver UI | |
| `tdp-deltalake` | Delta Lake | |
| `tdp-hive-metastore` | Hive Metastore | Integração: warehouse no S3 do Ozone |
| `tdp-iceberg` | Apache Iceberg | |
| `tdp-jupyter` | JupyterLab | |
| `tdp-kafka` | Apache Kafka (Strimzi) | Precisa do `tdp-operator` |
| `tdp-nifi` | Apache NiFi | |
| `tdp-openmetadata` | OpenMetadata | |
| `tdp-ozone` | Apache Ozone S3 | Vem com a segurança desligada (autenticação S3 desabilitada) |
| `tdp-postgresql` | PostgreSQL | |
| `tdp-ranger` | Apache Ranger | |
| `tdp-spark` | Apache Spark | Integração: s3a no S3 do Ozone |
| `tdp-superset` | Apache Superset | Integração: datasources do ClickHouse e do Trino |
| `tdp-trino` | Trino SQL engine | Integração: catálogos hive, iceberg e clickhouse |

---

## Troubleshooting

| Sintoma | Causa | Solução |
| --- | --- | --- |
| App of Apps: `current: app path does not exist` | `current/` nunca foi publicado | Renderizar e publicar `current/` |
| Pods em `Pending`: `unbound immediate PersistentVolumeClaims` | O PVC não tem StorageClass e o cluster não tem uma classe padrão | Definir `TDP_STORAGE_CLASS` (ou marcar uma StorageClass como padrão), renderizar de novo com `--force`, publicar e então apagar o StatefulSet e os PVCs não vinculados para o ArgoCD recriá-los |
| `ImagePullBackOff` em uma imagem `tdp/` | Não existe o Secret `tdp-registry` em `TDP_NAMESPACE` | `./deploy.sh -c -v variables.env.local` |
| Sync travado em `waiting for healthy state` | Um sync esperando pods que nunca ficam saudáveis não tem timeout, então novos commits ficam aguardando | Corrigir a causa e então usar Terminate na operação, na interface do ArgoCD; o auto-sync recomeça |
| Application `OutOfSync` depois de um push | Ainda não foi atualizada | `kubectl annotate application <nome> -n <TDP_PROJECT_NAMESPACE> argocd.argoproj.io/refresh=hard --overwrite` |
| Variáveis não substituídas (`${VAR}` no cluster) | Um template de `available/` ou `common/` foi aplicado diretamente | Sempre aplicar ou publicar `current/`, renderizado pelo `deploy.sh` |
| Erros de autenticação no git ou no registry | Credenciais erradas, ou um `$` sem aspas no `variables.env.local` | Verificar `kubectl -n <ARGOCD_NAMESPACE> get secret tdp-devops-repo tdp-helm-oci-tdp`; rodar `./deploy.sh -c` de novo |

Debug de sync:

```bash
# Eventos da Application
kubectl describe application <nome> -n <TDP_PROJECT_NAMESPACE>

# Logs do application controller
kubectl logs -n <ARGOCD_NAMESPACE> -l app.kubernetes.io/name=tdp-argocd-application-controller --tail=100
```

---

## Segurança

- O `variables.env.local` e os `current/common/*-secret.yaml` renderizados estão no `.gitignore` — nunca commitar tokens ou senhas.
- Vários `values.yaml` vêm com senhas de exemplo (ex.: `tdp-ranger`, `tdp-cloudbeaver`, `tdp-jupyter`, `tdp-airflow`), e o `values-integration.yaml` usa senhas `change-me-*` compartilhadas entre ClickHouse, Trino e Superset — são placeholders só para uso local/demo. **Troque antes de qualquer deploy real.**
- O `values-integration.yaml` aponta para o S3 Gateway do Ozone com a segurança desligada: as chaves S3 ali não são credenciais reais, e qualquer cliente lê e grava. Habilite a segurança do Ozone (Kerberos) e secrets S3 reais para qualquer uso além de demonstração.
- Configure TLS em todos os Ingress, incluindo o da interface do ArgoCD.
- Use uma conta robot somente de pull no registry, e troque os tokens do git e do registry regularmente.
- O `TDP_PROJECT_NAMESPACE` deve ter RBAC restrito: Applications ali podem fazer deploy em qualquer lugar que o AppProject permita.

---

## Desenvolvimento (interno)

> Este arquivo (`README-DEV.md`) e a pasta `scripts/` ficam fora da publicação no Tecnisys-OSS/tdp-k8s-gitops.

- **`values.yaml` vem do chart.** O `values.yaml` de `available/<componente>/` é uma cópia de `stack/charts/tdp/<componente>/values.yaml`. Depois de alterar o chart, rode `scripts/sync-values-from-charts.sh [componente...]` para atualizar o kit. O `publish-github.sh` faz o mesmo antes de publicar, então editar o `values.yaml` do kit diretamente não adianta: a mudança é perdida na próxima publicação.
- **Padrões só do fluxo GitOps** vão em `values-gitops.yaml` / `values-integration.yaml`, que nunca são sobrescritos.
- **Somente o registry de produção.** O kit só referencia `registry.tecnisys.com.br`. O `sync-values-from-charts.sh` aplica a mesma reescrita do pipeline de release (`registry.engtecnisys.com.br/tdp-dev/` → `registry.tecnisys.com.br/tdp/`, depois o host), converte `*.tdp.local` no placeholder `${TDP_DOMAIN}` e falha se sobrar `tdp-dev/` (referência dividida entre `registry` e `repository` no chart: mantenha host e projeto na mesma string). O `deploy.sh` avisa se algo em `current/` apontar para o Harbor de desenvolvimento.
- **Teste de regressão.** `tests/charts/render-regression/test.sh` verifica (SP-3) que o kit renderiza a imagem do Spark de produção, sem host duplicado.
