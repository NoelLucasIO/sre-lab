# envs/lab

```bash
set -a; source ~/.config/terraform/pg.env; source ~/.config/terraform/grafana.env; set +a
terraform init
terraform plan
```
