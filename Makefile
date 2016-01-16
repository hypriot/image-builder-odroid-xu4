default: build

build:
	docker build -t image-builder-odroid-xu4 .

sd-image: build
	docker run --rm --privileged -v $(shell pwd):/workspace -v /boot:/boot -v /lib/modules:/lib/modules image-builder-odroid-xu4

shell: build
	docker run -ti --privileged -v $(shell pwd):/workspace -v /boot:/boot -v /lib/modules:/lib/modules image-builder-odroid-xu4 bash
