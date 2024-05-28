#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color

echo ""
echo -e "${MAGENTA}"
echo "Sandybox"
echo -e "${NC}"

echo -e "${CYAN}"
echo "         ______________"
echo "        | how may I    |"
echo "        | assist you   |"
echo "        | today?       |"
echo "        |______________|"
echo "                 \\                       |"
echo "                  \\                      |"
echo "                   \\                     |"
echo "   _______                   ________    |"
echo "  |ooooooo|      ____       | __  __ |   |"
echo "  |[]+++[]|     [____]      |/  \\/  \\|   |"
echo "  |+ ___ +|     ]()()[      |\\__/\\__/|   |"
echo "  |:|   |:|   ___\\__/___    |[][][][]|   |"
echo "  |:|___|:|  |__|    |__|   |++++++++|   |"
echo "  |[]===[]|   |_|/  \\|_|    | ______ |   |"
echo "_ ||||||||| _ | | __ | | __ ||______|| __|"
echo "  |_______|   |_|[::]|_|    |________|   \\"
echo "              \\_|_||_|_/                  \\"
echo "                |_||_|                     \\"
echo "               _|_||_|_                     \\"
echo "      ____    |___||___|                     \\"
echo -e "${NC}"

# Mask systemd-networkd-wait-online.service to prevent boot delays
sudo systemctl mask systemd-networkd-wait-online.service

# Set Permissions
sudo chown -R $(whoami):$(whoami) .
sudo chmod -R 755 .

# Function to install system dependencies
function install() {
    local package=$1
    echo "Ensuring package '$package' is installed..."

    # Detect the package management system
    if command -v apt-get >/dev/null; then
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            sudo yes | add-apt-repository universe >/dev/null 2>&1 || true
            sudo apt update || true
            if [ "$package" == "docker" ]; then
                sudo apt-get install -y docker.io
            else
                sudo apt-get install -y "$package"
            fi
        fi
    elif command -v yum >/dev/null; then
        if ! rpm -q "$package" >/dev/null 2>&1; then
            sudo yum install -y epel-release >/dev/null 2>&1 || true
            sudo yum makecache --timer || true
            sudo yum install -y "$package"
        fi
    elif command -v dnf >/dev/null; then
        if ! dnf list installed "$package" >/dev/null 2>&1; then
            sudo dnf install -y epel-release >/dev/null 2>&1 || true
            sudo dnf makecache --timer || true
            sudo dnf install -y "$package"
        fi
    elif command -v zypper >/dev/null; then
        if ! zypper se -i "$package" >/dev/null 2>&1; then
            sudo zypper refresh || true
            sudo zypper install -y "$package"
        fi
    elif command -v pacman >/dev/null; then
        if ! pacman -Q "$package" >/dev/null 2>&1; then
            sudo pacman -Sy
            sudo pacman -S --noconfirm "$package"
        fi
    else
        echo "Package manager not supported."
        return 1
    fi

    if [ "$package" == "docker" ]; then
        if ! docker ps >/dev/null 2>&1; then
            echo "Docker installed. Adding $(whoami) to the 'docker' group..."
            sudo usermod -aG docker $(whoami)
            echo -e "${RED}User added to \`docker\` group but the session must be reloaded to access the Docker daemon. Please log out, log back in, and rerun the script. Exiting...${NC}"
            exit 0
        fi
    fi
}

install chrony
install nginx
install containerd
install docker
install docker-buildx-plugin
install alsa-utils
sudo systemctl enable docker
sudo systemctl start docker

# Create ALSA config (asound.conf, adjust as needed)
sudo tee /etc/asound.conf > /dev/null <<EOF
pcm.!default { type hw card 0 }
ctl.!default { type hw card 0 }
EOF

# Install Docker Buildx plugin
mkdir -p $HOME/.docker/cli-plugins
curl -Lo $HOME/.docker/cli-plugins/docker-buildx https://github.com/docker/buildx/releases/download/v0.14.0/buildx-v0.14.0.linux-arm64
sudo chmod +x $HOME/.docker/cli-plugins/docker-buildx
docker buildx version

# Setup UFW Firewall
echo "Setting up UFW Firewall..."
if which firewalld >/dev/null; then
    sudo systemctl stop firewalld
    sudo systemctl disable firewalld
    sudo yum remove firewalld -y 2>/dev/null || sudo apt-get remove firewalld -y 2>/dev/null || sudo zypper remove firewalld -y 2>/dev/null
fi
if ! which ufw >/dev/null; then
    sudo yum install ufw -y 2>/dev/null || sudo apt-get install ufw -y 2>/dev/null || sudo zypper install ufw -y 2>/dev/null
fi
sudo ufw allow ssh
sudo ufw allow 80,443/tcp
sudo ufw allow 5353/udp
echo "y" | sudo ufw enable

# Setup NGINX for reverse proxy
echo "Setting up NGINX..."
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
sudo tee /etc/nginx/sites-available/sandybox <<EOF
server {
    listen 80;
    location / {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# Remove sandybox site symlink if it exists
[ -L "/etc/nginx/sites-enabled/sandybox" ] && sudo unlink /etc/nginx/sites-enabled/sandybox

# Remove the default site if it exists
[ -L "/etc/nginx/sites-enabled/default" ] && sudo unlink /etc/nginx/sites-enabled/default

# Create a symlink to the sandybox site and reload NGINX
sudo ln -s /etc/nginx/sites-available/sandybox /etc/nginx/sites-enabled
sudo systemctl enable nginx
sudo nginx -t && sudo systemctl restart nginx

sudo systemctl status --no-pager nginx

if [[ "$1" != "--no-build" ]]; then
    [ -d ~/sandybox ] && rm -rf ~/sandybox
    git clone https://github.com/jeffloyd/sandybox ~/sandybox
    cd ~/sandybox
    echo "Checking if the container 'sandybox' is already running..."
    if [ $(docker ps -q -f name=sandybox) ]; then
        echo "Stopping running container 'sandybox'..."
        docker stop sandybox
    fi

    echo "Checking for existing container 'sandybox'..."
    if [ $(docker ps -aq -f status=exited -f name=sandybox) ]; then
        echo "Removing existing container 'sandybox'..."
        docker rm -f sandybox
    fi

    echo "Pruning Docker system..."
    docker system prune -f

    # Check if the buildx builder exists, if not create and use it
    if ! docker buildx ls | grep -q mybuilder; then
        docker buildx create --name mybuilder --use
        docker buildx inspect --bootstrap
    fi

    # Building Docker image 'sandybox' for ARMhf architecture
    echo "Building Docker image 'sandybox' for ARMhf..."
    timeout 3600 docker buildx build --platform linux/arm64 -t sandybox --load .

    if [ $? -ne 0 ]; then
        echo "Docker build failed. Exiting..."
        exit 1
    fi

    echo "Container 'sandybox' is now ready to run."

    echo "Running container 'sandybox' from image 'sandybox'..."
    docker run --restart unless-stopped -d --name sandybox \
        --mount type=bind,source=/etc/asound.conf,target=/etc/asound.conf \
        --privileged \
        --net=host \
        --tmpfs /run \
        --tmpfs /run/lock \
        -v ~/sandybox:/app \
        -v /dev/snd:/dev/snd \
        -v /dev/shm:/dev/shm \
        -v /usr/share/alsa:/usr/share/alsa \
        -v /var/run/dbus:/var/run/dbus \
        -e OPENAI_API_KEY=$OPENAI_API_KEY \
        sandybox

    echo "Container 'sandybox' is now running."

    # Show status of the container
    docker ps -a | grep sandybox

    sleep 10

    # Show status of all programs managed by Supervisor
    docker exec -i sandybox supervisorctl status
fi

if [[ "$1" == "--no-build" ]]; then
    docker ps -aq -f name=sandybox | xargs -r docker rm -f
    docker pull jeffloyd/sandybox
    docker run --restart unless-stopped -d --name sandybox \
        --mount type=bind,source=/etc/asound.conf,target=/etc/asound.conf \
        --privileged \
        --net=host \
        --tmpfs /run \
        --tmpfs /run/lock \
        -v /dev/snd:/dev/snd \
        -v /dev/shm:/dev/shm \
        -v /usr/share/alsa:/usr/share/alsa \
        -v /var/run/dbus:/var/run/dbus \
        -e OPENAI_API_KEY=$OPENAI_API_KEY \
        jeffloyd/sandybox
    docker ps -a | grep sandybox
    sleep 10
    docker exec -i sandybox supervisorctl status
fi