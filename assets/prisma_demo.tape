# VHS tape: Prisma demo analyzing RabbitMQ with Rebar3

Output "assets/prisma_demo.gif"

Set Shell "bash"
Set FontSize 15
Set LineHeight 1.3
Set FontFamily "Menlo"
Set Width 1100
Set Height 640
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms

# Hidden setup
Hide
Type "source /Users/manuel/Projects/Altenwald/prisma/scripts/vhs_env.sh" Enter
Sleep 1s
Type "clear" Enter
Show

# 1. Empty terminal with prompt
Sleep 1s

# 2. Clone repository
Type "git clone https://github.com/rabbitmq/rabbitmq-server.git"
Sleep 400ms
Enter
Sleep 2.5s

# 3. Enter project directory
Type "cd rabbitmq-server"
Sleep 400ms
Enter
Sleep 1s

# 4. Add Prisma plugin to rebar.config
Type "echo '{plugins, [prisma]}.' >> rebar.config"
Sleep 400ms
Enter
Sleep 1s

# 5. Build isolated dependency PPLT
Type "rebar3 prisma build"
Sleep 400ms
Enter
Sleep 2.5s

# 6. List generated .pplt cache file
Type "ls -lh *.pplt"
Sleep 400ms
Enter
Sleep 2s

# 7. Run Prisma static type & oxbow analysis
Type "rebar3 prisma"
Sleep 400ms
Enter

# Allow viewing the results
Sleep 6s
