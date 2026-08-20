# Local development only. Production frontend is a static build uploaded to S3
# by terraform/scripts/deploy_frontend.sh -- nothing runs this image in AWS.
FROM node:22-bookworm-slim

WORKDIR /app/frontend

COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci

COPY frontend/ /app/frontend/

EXPOSE 5173

CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]
