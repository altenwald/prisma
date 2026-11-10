const vscode = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;

function activate(context) {
    const config = vscode.workspace.getConfiguration('prisma');
    const command = config.get('serverPath') || 'prisma';
    const args = config.get('serverArguments') || ['lsp'];

    const serverOptions = {
        run: { command, args, transport: TransportKind.stdio },
        debug: { command, args, transport: TransportKind.stdio }
    };

    const clientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'erlang' },
            { scheme: 'file', language: 'elixir' }
        ],
        synchronize: {
            fileEvents: [
                vscode.workspace.createFileSystemWatcher('**/*.erl'),
                vscode.workspace.createFileSystemWatcher('**/*.hrl'),
                vscode.workspace.createFileSystemWatcher('**/*.ex'),
                vscode.workspace.createFileSystemWatcher('**/*.exs'),
                vscode.workspace.createFileSystemWatcher('**/*.pplt')
            ]
        }
    };

    client = new LanguageClient(
        'prisma_ls',
        'Prisma Language Server',
        serverOptions,
        clientOptions
    );

    client.start();
}

function deactivate() {
    if (!client) {
        return undefined;
    }
    return client.stop();
}

module.exports = {
    activate,
    deactivate
};
