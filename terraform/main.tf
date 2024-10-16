############################################################################
## terraformブロック
############################################################################
terraform {
  # Terraformのバージョン指定
  # TODO:その日が来たらアプデする
  required_version = "~> 1.7.0"

  # Terraformのaws用ライブラリのバージョン指定
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.33.0"
    }
  }

  # 簡単な検証なので、ローカルにtfstateを保持する
  backend "local" {
    path = "local.tfstate"
  }
}

############################################################################
## providerブロック
############################################################################
provider "aws" {
  # リージョンを指定
  region = "ap-northeast-1"
}

############################################################################
## localsブロック
############################################################################
locals {
  project = "stepfunction-manage-cache"

  lambda_base_path  = "../lambda"
  lambda_redis      = "operate-redis"
  lambda_redis_path = "${local.lambda_base_path}/${local.lambda_redis}"

  lambda_postgresql      = "operate-postgresql"
  lambda_postgresql_path = "${local.lambda_base_path}/${local.lambda_postgresql}"

  db_count = 0

  db_username = "testuser"
  db_password = "password"
  db_name     = "test"
}

############################################################################
## VPC
## 特に理由もないので、公式modulesを使用する
## natも不要なので、intra subnetのみ作成する
############################################################################
module "intra_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.9.0" # TODO: providerと一緒に更新する

  name = "${local.project}-intra-vpc"
  cidr = "10.0.1.0/24"

  azs                = ["ap-northeast-1a", "ap-northeast-1c"]
  intra_subnets      = ["10.0.1.0/25", "10.0.1.128/25"]
  enable_nat_gateway = false
}

############################################################################
## Lambda 2つ作る
## 共通で参照するリソース群を定義
############################################################################
# lambda用AWSロール
data "aws_iam_policy" "vpc_access_execution" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_vpc" {
  name               = "${local.project}-lambda-vpc-role"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_vpc.name
  policy_arn = data.aws_iam_policy.vpc_access_execution.arn
}

# lambda用セキュリティグループ
# VPC内のみ通信できればよい
resource "aws_security_group" "lambda_vpc" {
  name   = "${local.project}-lambda-vpc-sg"
  vpc_id = module.intra_vpc.vpc_id

  tags = {
    Name = "${local.project}-lambda-vpc-sg"
  }
}

resource "aws_security_group_rule" "lambda_vpc" {
  security_group_id = aws_security_group.lambda_vpc.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [module.intra_vpc.vpc_cidr_block]
}

############################################################################
## Lambda in VPC その１
## redisを操作するlambda関数
############################################################################
# ログ残す
resource "aws_cloudwatch_log_group" "redis" {
  name              = "/aws/lambda/${local.lambda_redis}"
  retention_in_days = 14
}

# zipを作成
data "archive_file" "redis" {
  type             = "zip"
  output_file_mode = "0666"
  source_dir       = local.lambda_redis_path
  output_path      = "${local.lambda_base_path}/${local.lambda_redis}.zip"
}

resource "aws_lambda_function" "redis" {
  function_name = local.lambda_redis
  role          = aws_iam_role.lambda_vpc.arn

  runtime  = "nodejs18.x"
  filename = data.archive_file.redis.output_path
  handler  = "index.handler"

  source_code_hash = filebase64sha256(data.archive_file.redis.output_path)

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.redis.name
  }

  vpc_config {
    subnet_ids         = module.intra_vpc.intra_subnets
    security_group_ids = [aws_security_group.lambda_vpc.id]
  }

  environment {
    variables = {
      # redisのaddressが評価できた場合、設定。countが0の場合はエラーになるので、tryでcatchしてnullを返却する。
      # coalesceはnullの場合第二引数をとる。冗長なcatchな気がする
      REDIS_HOST = coalesce(try(aws_elasticache_cluster.redis[0].cache_nodes[0].address, null), "DUMMY_REDIS_HOST")
    }
  }

  # zip内の変更は無視する
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

############################################################################
## Lambda in VPC その２
## postgresqlを操作するlambda関数
############################################################################
# ログ残す
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/lambda/${local.lambda_postgresql}"
  retention_in_days = 14
}

# zipを作成
data "archive_file" "postgresql" {
  type             = "zip"
  output_file_mode = "0666"
  source_dir       = local.lambda_postgresql_path
  output_path      = "${local.lambda_base_path}/${local.lambda_postgresql}.zip"
}

resource "aws_lambda_function" "postgresql" {
  function_name = local.lambda_postgresql
  role          = aws_iam_role.lambda_vpc.arn

  runtime  = "nodejs18.x"
  filename = data.archive_file.postgresql.output_path
  handler  = "index.handler"

  source_code_hash = filebase64sha256(data.archive_file.postgresql.output_path)

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.postgresql.name
  }

  vpc_config {
    subnet_ids         = module.intra_vpc.intra_subnets
    security_group_ids = [aws_security_group.lambda_vpc.id]
  }

  environment {
    variables = {
      # rdsのaddressが評価できた場合、設定。countが0の場合はエラーになるので、tryでcatchしてnullを返却する。
      # coalesceはnullの場合第二引数をとる。冗長なcatchな気がする
      DB_HOST     = coalesce(try(aws_db_instance.postgresql[0].address, null), "DUMMY_HOST") # port不要なのでaddressを取得する。endpointだとportもついてくる
      DB_USER     = coalesce(try(aws_db_instance.postgresql[0].username, null), "DUMMY_DB_USER")
      DB_PASSWORD = coalesce(try(aws_db_instance.postgresql[0].password, null), "DUMMY_DB_PASSWORD") # 簡単のため今回はこの方法で参照するが、tfstateに記載されるので、本来はsecret managerから取得するべき
      DB_DATABASE = coalesce(try(aws_db_instance.postgresql[0].db_name, null), "DUMMY_DB_DATABASE")
    }
  }

  # zip内の変更は無視する
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

############################################################################
## ElastieCache SSO Redis
## valkeyはドキュメント少なそうだったので、とりあえずRedisを選択
## クラスタなどは不要なので最小構成で作成する
############################################################################
resource "aws_elasticache_subnet_group" "redis" {
  name       = "redis-cache-intra-subnet"
  subnet_ids = module.intra_vpc.intra_subnets
}

resource "aws_security_group" "redis" {
  name   = "${local.project}-redis-sg"
  vpc_id = module.intra_vpc.vpc_id

  tags = {
    Name = "${local.project}-redis-sg"
  }
}

resource "aws_security_group_rule" "redis" {
  security_group_id        = aws_security_group.redis.id
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "TCP"
  source_security_group_id = aws_security_group.lambda_vpc.id
}

resource "aws_elasticache_cluster" "redis" {
  # 節約のため不要時は削除
  count = local.db_count

  cluster_id           = "${local.project}-cluster-example"
  engine               = "redis"
  node_type            = "cache.t2.medium" # aws_elasticache_cluster.redis: Creation complete after 5m17s
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]
}

############################################################################
## RDS postgresql
## エンジンはなんでもいいので、なんとなくpostgresql
## クラスタなどは不要なので最小構成で作成する
############################################################################
resource "aws_db_subnet_group" "postgresql" {
  name       = "${local.project}-intra-subnet"
  subnet_ids = module.intra_vpc.intra_subnets

  tags = {
    Name = "${local.project}-intra-subnet"
  }
}

resource "aws_security_group" "postgresql" {
  name   = "${local.project}-postgresql-sg"
  vpc_id = module.intra_vpc.vpc_id

  tags = {
    Name = "${local.project}-postgresql-sg"
  }
}

resource "aws_security_group_rule" "postgresql" {
  security_group_id        = aws_security_group.postgresql.id
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "TCP"
  source_security_group_id = aws_security_group.lambda_vpc.id
}

resource "aws_db_instance" "postgresql" {
  # 節約のため不要時は削除
  count = local.db_count

  #################################################
  ## インスタンス基本設定
  #################################################
  identifier             = "${local.project}-rds-postgresql"
  engine                 = "postgres"
  engine_version         = "16.3"        # https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.DBVersions.html
  instance_class         = "db.t3.micro" # aws_db_instance.postgresql: Creation complete after 4m47s 
  vpc_security_group_ids = [aws_security_group.postgresql.id]

  #################################################
  ## DBアプリ設定
  #################################################
  db_name = local.db_name

  #################################################
  ## ストレージ設定
  #################################################
  storage_type      = "gp2"
  storage_encrypted = false
  allocated_storage = 10
  # ストレージ自動スケーリング上限（GB）
  max_allocated_storage = 30

  #################################################
  ## ログイン情報
  ## adminは基本的にアプリに使用しないが、簡単のため
  #################################################
  username = local.db_username
  password = local.db_password
  port     = 5432

  #################################################
  ## ネットワーク
  #################################################
  publicly_accessible  = false
  db_subnet_group_name = aws_db_subnet_group.postgresql.name
  multi_az             = false

  #################################################
  ## DBインスタンス管理
  #################################################
  backup_window = "09:10-09:40"
  # アップデートの実行を次のメンテナンスウィンドウまで待機
  apply_immediately          = false
  maintenance_window         = "mon:10:10-mon:10:40"
  auto_minor_version_upgrade = false

  #################################################
  ## 削除保護
  #################################################
  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = false
  backup_retention_period  = 0
}

############################################################################
## Step Functions
## 本体はGUIで作成するので、ロールだけ用意
## 作業証跡を残すため、sfn本体も一時的に定義
############################################################################
# Step Functions用のIAMロールを作成
data "aws_iam_policy_document" "assume_sfn" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${local.project}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.assume_sfn.json
}

data "aws_iam_policy_document" "sfn" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "lambda:InvokeFunction",
    ]
    resources = [
      "${aws_lambda_function.redis.arn}:*",
      "${aws_lambda_function.postgresql.arn}:*",
    ]
  }
}

resource "aws_iam_policy" "sfn" {
  name        = "${local.project}-sfn-policy"
  description = "IAM policy for Step Functions"
  policy      = data.aws_iam_policy_document.sfn.json
}

resource "aws_iam_role_policy_attachment" "sfn" {
  role       = aws_iam_role.sfn.name
  policy_arn = aws_iam_policy.sfn.arn
}

resource "aws_sfn_state_machine" "sfn" {
  name     = "${local.project}-sfn"
  role_arn = aws_iam_role.sfn.arn

  definition = templatefile("${path.module}/templates/sfn_templates.json", {
    lambda_arn = aws_lambda_function.redis.arn,
  })
}