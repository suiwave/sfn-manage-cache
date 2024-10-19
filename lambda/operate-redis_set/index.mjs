import { Redis } from "ioredis"

// ElastiCacheの接続情報
const redisConfig = {
    host: process.env.REDIS_HOST,
    port: 6379,
};

const redisClient = new Redis(redisConfig);

export const handler = async (event, context) => {
    console.log("========================================");
    console.log(process.env.REDIS_HOST);
    console.log("========================================");
    const res = await redisClient.set("test", "asfdaaaaa")
    console.log(res)
    console.log(111, await redisClient.get("test"));
    console.log(222, await redisClient.get("testaaaa")); // 存在しない場合、nullが返却される

    return {
        "statusCode": "200",
        "body": JSON.stringify({ "test": "value" })
    };
};
