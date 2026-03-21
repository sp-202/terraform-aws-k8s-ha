# Production environment - full-size instances (matches original defaults)
cluster_name = "k8s-ha-cluster"

# GP workers
gp_worker_instance_type = "im4gn.4xlarge"

# Spark critical
spark_critical_instance_type = "i4g.8xlarge"

# MinIO
minio_instance_type = "im4gn.8xlarge"

# Spot fleet - large instances for production spark workloads
worker_instance_type = "r6gd.12xlarge"
spot_overrides       = ["r6gd.12xlarge", "i4g.8xlarge"]
worker_count         = 3
worker_min           = 3
worker_max           = 4
