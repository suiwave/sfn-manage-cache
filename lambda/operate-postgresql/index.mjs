import pg from 'pg';
const { Client } = pg;

const client = new Client({
    host: process.env.DB_HOST,
    user: process.env.DB_USER,
    database: process.env.DB_DATABASE,
    password: process.env.DB_PASSWORD,
    port: 5432,
    // postgresqlはv15からデフォルトでsslが有効化されている
    // 参考：https://zenn.dev/ncdc/articles/bbc72e7522c144
    ssl: {
        rejectUnauthorized: false // 注意: オレオレで行く方法なので非推奨。本来はきちんとpemを使用すること
    }
});

client.connect();

const setup = async () => {
    // テーブルの作成 (既に存在する場合はスキップ)
    await client.query(`
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                name VARCHAR(100) NOT NULL,
                email VARCHAR(100) UNIQUE NOT NULL
            )
        `);

    // データの挿入
    const insertResult = await client.query(`
            INSERT INTO users (name, email) 
            VALUES ($1, $2) 
            RETURNING id`,
        ['John Doe', 'john@example.com']
    );
    console.log('Inserted user ID:', insertResult.rows[0].id);
}

export const handler = async (event, context) => {
    await setup();

    // データの選択
    const selectResult = await client.query('SELECT * FROM users');
    console.log('Selected users:', selectResult.rows);

    return {
        "statusCode": "200",
        "body": JSON.stringify({ "test": "value" })
    };
};
