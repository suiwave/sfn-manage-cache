import { Redis } from "ioredis"

// ElastiCacheの接続情報
const redisConfig = {
    host: process.env.REDIS_HOST,
    port: 6379,
};

// ウォームスタート時にコネクションを再利用する
const redisClient = new Redis(redisConfig);

export const handler = async (event, context) => {
    const key = event.email
    console.log(`key is ${key}`)
    const result = await redisClient.get(key) // 存在しない場合、nullが返却される

    return {
        "cache": result,
    };
};
