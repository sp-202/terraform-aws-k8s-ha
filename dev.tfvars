# Dev / Test environment - smaller instances to save cost
cluster_name = "k8s-dev-cluster"

# GP workers
gp_worker_instance_type = "c6gd.4xlarge"

# Spark critical
spark_critical_instance_type = "c6gd.4xlarge"

# MinIO
minio_instance_type = "is4gen.xlarge"

# Spot fleet - smaller 4xlarge instances
worker_instance_type = "c6gd.4xlarge"
spot_overrides       = ["c6gd.4xlarge", "m6gd.4xlarge", "c7gd.4xlarge"]
worker_count         = 1
worker_min           = 1
worker_max           = 2
