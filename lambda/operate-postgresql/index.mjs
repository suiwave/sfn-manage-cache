import pg from 'pg';
const { Client } = pg;

const client = new Client({
    user: process.env.DB_USER,
    host: process.env.RDS_ENDPOINT,
    database: process.env.DB_DATABASE,
    password: process.env.DB_PASSWORD,
    port: 5432,
});

client.connect();

export const handler = async (event, context) => {

    const result = await client.query('SELECT NOW()');
    console.log(111, result);

    return {
        "statusCode": "200",
        "body": JSON.stringify({ "test": "value" })
    };
};
