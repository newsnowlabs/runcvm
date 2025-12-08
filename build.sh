sudo docker build --progress=plain --platform linux/arm64 -t runcvm:arm64 . 2>&1 | tee build.log
sudo rm -rf /opt/runcvm/*
sudo docker run --rm -v /opt/runcvm:/runcvm runcvm:arm64 --quiet
#sudo systemctl restart k3s 
