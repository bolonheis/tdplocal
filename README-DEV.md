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
│   │                     #   values-ozone-security.yaml segurança do Ozone (só com TDP_OZONE_SECURITY=true)
│   ├── tdp-clickhouse/
│   ├── …
│   └── tdp-trino/
├── current/          # Renderizado pelo deploy.sh — commitado no git,
│                     # exceto current/common/*-secret.yaml (no .gitignore)
├── variables.env     # Variáveis de referência (não editar, copiar para variables.env.local)
├── deploy.sh         # Script de renderização e deploy
├── enable-ozone-security.sh  # Liga a segurança do Ozone (ver Segurança do Ozone)
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
| Licença da TDP | Dois arquivos da Tecnisys: as chaves públicas confiáveis (`keys.json`) e o lease assinado (`lease.json`). O ArgoCD e todos os componentes da TDP se recusam a instalar sem uma licença VALID; o `deploy.sh --install` instala a licença primeiro (veja o Passo 3) |
| Instalados pelo administrador do cluster | `tdp-operator` (operators do Kafka e do ClickHouse), via `helm install`, fora deste fluxo GitOps. Como todo chart da TDP, exige a licença instalada antes |

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
| `TDP_LICENSE_PUBLIC_KEYS_FILE`, `TDP_LICENSE_FILE` | `license/keys.json`, `license/lease.json` | Os arquivos de licença da Tecnisys, relativos ao arquivo de variáveis. `license/` está no `.gitignore`. O lease também pode ser o manifesto do Secret `tecnisys-license-lease` |
| `TDP_LICENSE_NAMESPACE` | `tdp-system` | Onde ficam o `tdp-license-operator` e o `PlatformLicense` (padrão `tdp-system`) |
| `TDP_LICENSE_POLICY_NAMESPACES` | `tdp,tdp-data` | Namespaces cujos workloads licenciados a licença controla, separados por vírgula (vazio = `TDP_NAMESPACE`) |
| `TDP_DEFAULT_PASSWORD` | `'ChangeMe!T3c'` | Valor usado por todo `TDP_*_PASSWORD` vazio abaixo |
| `TDP_<COMPONENTE>_..._PASSWORD` | vazio | Logins de admin das interfaces (Airflow, CloudBeaver, Jupyter, Kafka UI, Ranger, Superset) e os usuários de banco definidos nos values (PostgreSQL embutido do Airflow, Hive, Hue e Superset, Ranger, usuários `trino`/`superset` do ClickHouse); a lista está no `variables.env` |
| `TDP_SUPERSET_SECRET_KEY` | vazio | `SECRET_KEY` do Superset (assina as sessões e criptografa as senhas de conexão que o Superset guarda). Vazio: o `deploy.sh` mantém a chave já renderizada em `current/tdp-superset/`, ou gera uma na primeira renderização; copie-a para o seu arquivo de variáveis para fixá-la |
| `TDP_HUE_SECRET_KEY` | vazio | Chave secreta do Hue (assina as sessões e os tokens CSRF). Mesmo tratamento do `TDP_SUPERSET_SECRET_KEY`; uma chave nova desconecta todos os usuários do Hue |
| `TDP_OZONE_SECURITY` | `false` | Segurança do Ozone (Kerberos e autenticação S3 real). Gravado pelo `enable-ozone-security.sh`; ver [Segurança do Ozone](#segurança-do-ozone) |
| `TDP_OZONE_KDC_MASTER_PASSWORD` | vazio | Senha mestra do KDC do Ozone, usada uma vez para criar o banco do KDC. Vazio: o `deploy.sh` mantém a que já está em `current/tdp-ozone/`, ou gera uma |

As senhas só entram nos arquivos dos componentes (o `deploy.sh` as valida quando renderiza um componente): no mínimo 8 caracteres de `A-Z a-z 0-9 ! . _ ~ -`, porque são escritas sem escape em YAML, XML, shell, SQL e URIs de banco. Uma credencial compartilhada usa a mesma variável nos dois lados, por exemplo `TDP_CLICKHOUSE_TRINO_PASSWORD` define o usuário `trino` do ClickHouse e o catálogo `clickhouse` do Trino. Elas valem na criação do usuário; trocar depois não altera a senha de um usuário existente, e os `current/<componente>/values*.yaml` já existentes só são renderizados de novo com `--force`. O admin do OpenMetadata (`admin@open-metadata.org` / `admin`) é criado pelo próprio OpenMetadata e não é coberto.

### Passo 3 — Instalar os CRDs, a licença e o ArgoCD

Coloque os dois arquivos de licença da Tecnisys onde `TDP_LICENSE_PUBLIC_KEYS_FILE` e `TDP_LICENSE_FILE` apontam (por padrão `license/keys.json` e `license/lease.json`, ao lado do arquivo de variáveis) e rode:

```bash
./deploy.sh --install -v variables.env.local
```

O que é executado, em ordem:

1. `helm registry login` — autentica no registry OCI.
2. `helm upgrade --install tdp-crds` — os CRDs do cluster; pulado quando os CRDs do ArgoCD e os da licença já existem.
3. A licença, em `TDP_LICENSE_NAMESPACE`: o pull secret `tdp-registry`, `helm upgrade --install tdp-license` (o tdp-license-operator e o webhook de admissão dele, confiando nas chaves públicas), o Secret `tecnisys-license-lease` e um par `LicensePolicy` + `PlatformLicense` para a plataforma inteira. Depois aguarda o operator verificar o lease e **para se a licença não estiver VALID**.
4. `helm upgrade --install tdp-argo` — o ArgoCD em `ARGOCD_NAMESPACE`, com `application.namespaces: "*"`, para gerenciar Applications em qualquer namespace, e a interface exposta em `argo.${TDP_DOMAIN}` conforme `TDP_EXPOSE` (veja o Passo 4); aguarda o server e o application controller.
5. `envsubst` em `common/` → `current/common/`. Os componentes são renderizados à parte, no Passo 6.
6. `kubectl apply` de `current/common/` (criando o `TDP_NAMESPACE` se necessário):
   - `argo-gitops-appproject.yaml` — o AppProject da TDP
   - `tdp-devops-repo-secret.yaml` — credencial git para o ArgoCD
   - `tdp-registry-secret.yaml` — credencial do Helm OCI registry para o ArgoCD
   - `tdp-image-pull-secret.yaml` — o image pull secret `tdp-registry` em `TDP_NAMESPACE`. Um `tdp-registry` existente é mantido, a menos que se use `--force`.
   - `argo-gitops-app-of-apps.yaml` — o App of Apps

#### A trava de licença

Todo chart da TDP (`tdp-argo`, `tdp-operator` e cada componente de `available/`) se recusa a instalar a menos que o `tdp-license-operator` esteja rodando e um `PlatformLicense` que o cubra esteja VALID (ou WARNING) e tenha sido verificado pelo operator nos últimos 10 minutos:

- `helm install`/`upgrade` (como o `--install` faz com o `tdp-argo`) falha antes de criar qualquer coisa, com a mensagem `[<chart>] license check failed: …`.
- O ArgoCD não consegue fazer essa verificação ao renderizar, então cada chart também renderiza um Job de hook PreSync `<release>-license-check` que a executa. Sem licença válida, o hook falha e o ArgoCD não aplica nada daquela Application; quando a licença volta a ficar VALID, o próximo sync passa.

> **Usando um ArgoCD instalado por você?** Pule o `--install`: rode `./deploy.sh --license -v variables.env.local` para instalar a licença e depois `./deploy.sh -c -v variables.env.local`. Garanta que esse ArgoCD gerencie Applications em `TDP_PROJECT_NAMESPACE`:
>
> ```bash
> kubectl patch configmap argocd-cm -n <namespace-do-argocd> --type merge \
>   -p '{"data":{"application.namespaces":"<TDP_PROJECT_NAMESPACE>"}}'
> kubectl rollout restart deployment argocd-server -n <namespace-do-argocd>
> kubectl rollout restart statefulset argocd-application-controller -n <namespace-do-argocd>
> ```

#### Limite de nós de trabalho

Uma licença também pode limitar quantos nós do Kubernetes podem executar a TDP. O operator conta os nós que executam pods com o label `tecnisys.com/licensed=true` nos `TDP_LICENSE_POLICY_NAMESPACES`. Quando há mais nós do que a licença permite por mais de 15 minutos, ele informa `UNDER_LICENSED`: `kubectl get platformlicense -A` mostra `NODES`, `MAX` e `CAPACITY`, e são gerados um evento `UnderLicensed` e a métrica `tecnisys_license_under_licensed`. É só um alerta: nada é parado ou recusado. Num cluster atualizado a partir de um kit mais antigo, o `deploy.sh` avisa quando o CRD `PlatformLicense` é antigo demais para informar isso, e mostra os comandos para atualizá-lo.

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
| 1. Armazenamento de objetos | `tdp-ozone` | Crie os buckets `warehouse` e `clickhouse-data` no volume `/s3v` do Ozone (com a segurança do Ozone ligada, com a chave do `ozone-s3-credentials`: ver [Segurança do Ozone](#segurança-do-ozone)) |
| 2. Metadados e engines | `tdp-hive-metastore`, `tdp-spark`, `tdp-iceberg`, `tdp-trino` | Usam o S3 Gateway do Ozone |
| 3. Serviço e BI | `tdp-clickhouse`, `tdp-superset`, `tdp-hue` | O Superset importa os datasources do ClickHouse e do Trino; os editores do Hue consultam o Trino, o Spark SQL e o ClickHouse |
| 4. Qualquer ordem | `tdp-airflow`, `tdp-kafka`, `tdp-nifi`, `tdp-jupyter` e os demais | Kafka e ClickHouse precisam do `tdp-operator` |

---

## Arquivos de values

Cada Application aplica até quatro arquivos de values de `current/<componente>/`, nesta ordem — os posteriores prevalecem:

| Arquivo | Conteúdo | Na sincronização de release |
| --- | --- | --- |
| `values.yaml` | Padrões do chart (cópia do `values.yaml` do próprio chart) | Substituído pelos novos padrões do chart |
| `values-gitops.yaml` | Padrões GitOps: correções específicas do ArgoCD (ex.: Jobs de migração do Airflow como hooks Sync), autenticação S3 do Ozone desligada enquanto o Kerberos estiver desligado, a ingress/storage class de `TDP_INGRESS_CLASS`/`TDP_STORAGE_CLASS`, a exposição de `TDP_EXPOSE`, as senhas dos componentes de `TDP_*_PASSWORD`, espelhos de imagem em produção | Mantido |
| `values-integration.yaml` | Integração com os outros componentes TDP em `TDP_NAMESPACE`: catálogos do Trino (hive, iceberg, clickhouse), Spark, Hive Metastore e ClickHouse no S3 do Ozone, datasources do Superset, editores do Hue | Mantido |
| `values-ozone-security.yaml` | Só com `TDP_OZONE_SECURITY=true` (`tdp-ozone`, `tdp-trino`, `tdp-spark`, `tdp-hive-metastore`, `tdp-clickhouse`, `tdp-hue`): Kerberos e autenticação S3 no Ozone, e a chave S3 dos clientes a partir do `ozone-s3-credentials`. Ver [Segurança do Ozone](#segurança-do-ozone) | Mantido |

- Maps são mesclados chave a chave, então um overlay só contém as chaves que muda. Listas e strings de várias linhas são substituídas por inteiro.
- Uma `TDP_INGRESS_CLASS`/`TDP_STORAGE_CLASS` vazia é renderizada como `null`, o que remove a chave: vale o padrão do chart.
- Os overlays são opcionais: apague um deles de `current/<componente>/` para não usá-lo (as Applications usam `ignoreMissingValueFiles: true`).
- O `values-integration.yaml` supõe que os componentes referenciados estão instalados com os nomes padrão em `TDP_NAMESPACE`, e pega as senhas de ClickHouse, Trino e Superset do `variables.env`.
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

## Segurança do Ozone

O `tdp-ozone` vem com a segurança desligada: não há Kerberos entre os seus daemons, e o S3 Gateway aceita qualquer chave, então qualquer cliente do cluster lê e grava em qualquer bucket. Os outros componentes usam chaves fictícias (`values-integration.yaml`). Esse é o padrão para o primeiro deploy; ligue a segurança para qualquer uso além de demonstração.

### O que muda ao ligá-la

- O `tdp-ozone` ganha o KDC interno do Ozone (realm `TDP.LOCAL`), Kerberos entre OM, SCM, datanodes, S3 Gateway e Recon, e autenticação S3 real.
- Um Job PostSync pede ao OM uma chave S3, do admin do Ozone `tdp-s3-admin`, e a guarda no Secret `ozone-s3-credentials` em `TDP_NAMESPACE`. Todos os clientes abaixo usam essa chave, então todos agem como o admin do Ozone.
- Cada cliente ganha um `values-ozone-security.yaml` que lê a chave desse Secret no lugar das chaves fictícias:

| Componente | Como lê a chave |
| --- | --- |
| `tdp-trino` | env `AWS_*` no coordinator e nos workers; os catálogos `hive` e `iceberg` usam `${ENV:AWS_ACCESS_KEY_ID}` |
| `tdp-spark` | env `AWS_*` no master, nos workers, no Thrift Server e no History Server; o `core-site.xml` usa `${env.AWS_ACCESS_KEY_ID}` |
| `tdp-hive-metastore` | `metastore.s3.existingSecret` |
| `tdp-clickhouse` | env `AWS_*` nos pods do servidor; o disco `ozone` usa `from_env` |
| `tdp-hue` | Já lê o Secret; o overlay remove o valor fictício de reserva |

- As interfaces web do OM, SCM, Recon e S3 Gateway continuam sem autenticação.
- Drivers Spark que rodam fora dos pods do `tdp-spark` (Jupyter, Airflow) precisam eles mesmos de `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` desse Secret.
- Não dá para desligá-la pelo kit: quando `current/` tem um `values-ozone-security.yaml`, o `deploy.sh` se recusa a renderizar com `TDP_OZONE_SECURITY=false`.

### Como ligar

Faça isso antes do primeiro sync do `tdp-ozone`. Ligar a segurança num Ozone que já guarda dados não foi testado; teste numa cópia antes.

```bash
./enable-ozone-security.sh -v variables.env.local
git add current/ && git commit -m "feat: enable Ozone security" && git push
```

O script:

1. Confere se o chart `tdp-ozone` em `HELM_CHART_VERSION` roda a exportação dos keytabs como hook Sync do ArgoCD: builds antigos nunca terminam o primeiro sync com a segurança ligada. Precisa de `helm` e acesso ao registry; `--skip-chart-check` pula a conferência.
2. Pede confirmação (`-y` pula) e grava `TDP_OZONE_SECURITY=true` no seu arquivo de variáveis.
3. Renderiza o `tdp-ozone` e os clientes acima que já estão em `current/` com `deploy.sh -p`, acrescentando o `values-ozone-security.yaml` deles e mantendo os outros arquivos de values. Componentes renderizados depois recebem o seu pelo `deploy.sh`.

O `TDP_OZONE_KDC_MASTER_PASSWORD` é gerado na primeira renderização quando vazio, e mantido em `current/tdp-ozone/values-ozone-security.yaml`.

### O que acontece no sync

1. O `tdp-ozone` sincroniza o KDC (sync wave -2), um Job hook Sync que exporta os keytabs para Secrets (wave -1) e depois os daemons do Ozone. Em seguida um Job PostSync preenche o `ozone-s3-credentials`:

   ```bash
   kubectl -n <TDP_NAMESPACE> get secret ozone-s3-credentials -o jsonpath='{.data.aws_access_key_id}'
   ```

2. Pods dos clientes que sobem antes disso ficam em `CreateContainerConfigError` e sobem sozinhos quando ele é preenchido. Pods que já estavam rodando ficam com as chaves antigas: reinicie os Deployments e StatefulSets do `tdp-trino`, `tdp-spark`, `tdp-hive-metastore`, `tdp-clickhouse` e `tdp-hue` (**Restart** na interface do ArgoCD, ou `kubectl rollout restart`).
3. Crie os buckets `warehouse` e `clickhouse-data` com essa chave, se ainda não existirem:

   ```bash
   NS=<TDP_NAMESPACE>
   export AWS_ACCESS_KEY_ID=$(kubectl -n $NS get secret ozone-s3-credentials -o jsonpath='{.data.aws_access_key_id}' | base64 -d)
   export AWS_SECRET_ACCESS_KEY=$(kubectl -n $NS get secret ozone-s3-credentials -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)
   kubectl -n $NS port-forward svc/tdp-ozone-s3g-rest 9878:9878 &
   aws s3 mb s3://warehouse --endpoint-url http://localhost:9878 --region us-east-1
   aws s3 mb s3://clickhouse-data --endpoint-url http://localhost:9878 --region us-east-1
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
| Renovar a licença | Substituir o arquivo para o qual `TDP_LICENSE_FILE` aponta (e o de `TDP_LICENSE_PUBLIC_KEYS_FILE`, se a Tecnisys enviar chaves novas) e rodar `./deploy.sh --license -v variables.env.local`. Workloads parados por licença expirada voltam sozinhos |

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
| `--install` | **Primeira instalação**: helm login → tdp-crds → licença (tdp-license-operator, lease, `PlatformLicense`; aguarda VALID) → tdp-argo (exposto em `argo.${TDP_DOMAIN}` conforme `TDP_EXPOSE`) → aguarda ready → renderiza → aplica common |
| `--license` | Instala ou renova só a licença: tdp-crds (se faltar) → tdp-license-operator → lease → `PlatformLicense`, aguarda VALID e para |
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

# Ligar a segurança do Ozone (Kerberos + autenticação S3 real) e depois publicar
./enable-ozone-security.sh -v variables.env.local

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
| `tdp-hue` | Hue SQL Editor | Inclui o próprio PostgreSQL; integração: editores do Trino, Spark SQL, ClickHouse e PostgreSQL, arquivos no S3 do Ozone |
| `tdp-iceberg` | Apache Iceberg | |
| `tdp-jupyter` | JupyterLab | |
| `tdp-kafka` | Apache Kafka (Strimzi) | Precisa do `tdp-operator` |
| `tdp-nifi` | Apache NiFi | |
| `tdp-openmetadata` | OpenMetadata | |
| `tdp-ozone` | Apache Ozone S3 | Vem com a segurança desligada (autenticação S3 desabilitada); ver [Segurança do Ozone](#segurança-do-ozone) |
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
| `[tdp-argo] license check failed: …` no `--install`, ou no `helm install` de um chart da TDP | Sem `tdp-license-operator`, sem `PlatformLicense`, ou licença que não está VALID | Ler a mensagem, corrigir os arquivos de licença e rodar `./deploy.sh --license -v variables.env.local` |
| `kubectl get platformlicense -A` mostra `CAPACITY UNDER_LICENSED` | Mais nós executam pods licenciados da TDP do que a licença permite, há mais de 15 minutos. É só um alerta: nada é parado | `kubectl get pods -A -l tecnisys.com/licensed=true -o wide` mostra onde eles rodam; reduzir os nós em que a TDP roda, ou pedir à Tecnisys uma licença com mais nós |
| Sync de uma Application falha no hook PreSync `<release>-license-check` | O mesmo, para um componente sincronizado pelo ArgoCD | `kubectl -n <TDP_NAMESPACE> logs job/<release>-license-check`; quando `kubectl get platformlicense -A` mostrar VALID, sincronizar de novo |
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

- O `variables.env.local`, os `current/common/*-secret.yaml` renderizados e os arquivos de licença em `license/` estão no `.gitignore` — nunca commitar tokens ou senhas.
- As senhas dos componentes têm `ChangeMe!T3c` como padrão (`TDP_DEFAULT_PASSWORD`), e o `deploy.sh` avisa enquanto alguma ainda o usa. **Defina-as antes de qualquer deploy real.** Os `current/<componente>/values*.yaml` renderizados guardam as senhas em texto puro e são commitados: mantenha o repositório GitOps privado.
- O `values-integration.yaml` aponta para o S3 Gateway do Ozone com a segurança desligada: as chaves S3 ali não são credenciais reais, e qualquer cliente lê e grava. Ligue a [segurança do Ozone](#segurança-do-ozone) para qualquer uso além de demonstração.
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
