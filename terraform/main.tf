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
locals{
  project = "stepfunction-manage-cache"
  
  lambda_base_path = "../lambda"
  lambda_redis = "operate-redis"
  lambda_redis_path = "${local.lambda_base_path}/${local.lambda_redis}"

  lambda_postgresql = "operate-posgresql"
  lambda_postgresql_path = "${local.lambda_base_path}/${local.lambda_postgresql}"
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

  azs             = ["ap-northeast-1a", "ap-northeast-1c"]
  intra_subnets = ["10.0.1.0/25", "10.0.1.128/25"]
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
  name = "${local.project}-lambda-vpc-role"
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
    name = "${local.project}-lambda-vpc-sg"
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
      REDIS_ENDPOINT = aws_elasticache_cluster.redis.cache_nodes[0].address
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
    name = "${local.project}-redis-sg"
  }
}

resource "aws_security_group_rule" "redis" {
  security_group_id = aws_security_group.redis.id
  type              = "ingress"
  from_port         = 6379
  to_port           = 6379
  protocol          = "TCP"
  source_security_group_id = aws_security_group.lambda_vpc.id
}

resource "aws_elasticache_cluster" "redis" {
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