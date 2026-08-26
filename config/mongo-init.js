const semantic = db.getSiblingDB("semantic_uat");

function ensureRole(name, privileges) {
    const specification = { privileges: privileges, roles: [] };
    try {
        semantic.updateRole(name, specification);
    } catch (error) {
        semantic.createRole({ role: name, ...specification });
    }
}

function ensureUser(name, password, roles) {
    const specification = { pwd: password, roles: roles };
    try {
        semantic.updateUser(name, specification);
    } catch (error) {
        semantic.createUser({ user: name, ...specification });
    }
}

ensureRole("semanticQueryRead", [{ resource: { db: "semantic_uat", collection: "" }, actions: ["find", "listCollections", "listIndexes"] }]);
ensureRole("semanticIndexerWrite", [{ resource: { db: "semantic_uat", collection: "" }, actions: ["find", "insert", "update", "remove", "listCollections", "listIndexes"] }]);
ensureUser("semantic_bootstrap", process.env.SEMANTIC_MONGO_BOOTSTRAP_PASSWORD, ["dbOwner"]);
ensureUser("semantic_indexer", process.env.SEMANTIC_MONGO_INDEXER_PASSWORD, ["semanticIndexerWrite"]);
ensureUser("semantic_query", process.env.SEMANTIC_MONGO_QUERY_PASSWORD, ["semanticQueryRead"]);
