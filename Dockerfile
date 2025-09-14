# Small production base
FROM node:20-alpine

# Create app dir
WORKDIR /usr/src/app

# Install deps (leverage Docker layer cache)
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev

# Copy source
COPY . .

# App listens on 3000
EXPOSE 3000

# Run
CMD ["npm", "start"]
